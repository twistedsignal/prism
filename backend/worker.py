"""On-demand Blender worker. Only this process imports rendering dependencies."""

import json
import socket
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy
import assets
import config
import renderer
import schema
from render_cache import RenderCache
from scene import SceneCache, SceneError


def main():
    port, token, directory, cache = sys.argv[sys.argv.index("--") + 1:]
    directory = Path(directory)
    store = config.Store()
    scenes = SceneCache(cache, assets.Resolver(cache, lambda: store.get_config()["ravenPath"]))
    render_cache = RenderCache()
    engine = None
    with socket.create_connection(("127.0.0.1", int(port)), timeout=30) as connection:
        connection.settimeout(None)
        with connection.makefile("rwb") as stream:
            stream.write(json.dumps({"token": token, "version": bpy.app.version_string}).encode() + b"\n")
            stream.flush()
            for line in stream:
                try:
                    request = json.loads(line)
                    if request["operation"] == "scene":
                        payload = json.loads((directory / "scene.json").read_bytes())
                        identifier, warnings = scenes.add(b"", payload)
                        result = {"sceneId": identifier, "warnings": warnings, "incomplete": scenes.incomplete(identifier)}
                    elif request["operation"] == "render":
                        identifier = request["sceneId"]
                        if not scenes.exists(identifier):
                            raise SceneError("Unknown scene; send it again")
                        if engine is None:
                            engine = renderer.Renderer()
                        settings = schema.normalize(request.get("settings"))
                        size, aa = request["size"], request["aa"]
                        key = (identifier, json.dumps(settings, sort_keys=True), size, aa)
                        pixels = render_cache.get(key)
                        if pixels is None:
                            model = engine.load(scenes.path(identifier))
                            pixels = engine.render(model, settings, size, aa)
                            render_cache.put(key, pixels)
                        if request["format"] == "png":
                            renderer.save_png_pixels(pixels, directory / "render.png")
                        else:
                            (directory / "render.rgba").write_bytes(renderer.to_rgba8_top_down(pixels))
                        result = {}
                    else:
                        raise ValueError("Unknown worker operation")
                    response = {"ok": True, "result": result}
                except Exception as error:
                    traceback.print_exc()
                    response = {"ok": False, "error": str(error), "sceneError": isinstance(error, SceneError)}
                stream.write(json.dumps(response).encode() + b"\n")
                stream.flush()


if __name__ == "__main__":
    main()
