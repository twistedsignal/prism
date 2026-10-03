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
import memory
import renderer
import schema
from render_cache import RenderCache
from scene import SceneCache, SceneError


def main():
    port, token, directory, cache = sys.argv[sys.argv.index("--") + 1:]
    directory = Path(directory)
    store = config.Store()
    scenes = SceneCache(cache, assets.Resolver(cache, lambda: store.get_config()["ravenPath"]))
    # Final images for previews, thumbnails and exports; small, since effect edits are cheap to redo.
    render_cache = RenderCache(max_bytes=16 * 1024 * 1024)
    engine = None
    with socket.create_connection(("127.0.0.1", int(port)), timeout=30) as connection:
        connection.settimeout(None)
        with connection.makefile("rwb") as stream:
            stream.write(json.dumps({"token": token, "version": bpy.app.version_string}).encode() + b"\n")
            stream.flush()
            def progress(stage, completed, total):
                stream.write(json.dumps({"progress": {"stage": stage, "completed": completed, "total": total}}).encode() + b"\n")
                stream.flush()

            for line in stream:
                try:
                    request = json.loads(line)
                    if request["operation"] == "scene":
                        progress("Preparing scene", 0, 1)
                        payload = json.loads((directory / "scene.json").read_bytes())
                        identifier, warnings = scenes.add(b"", payload)
                        result = {"sceneId": identifier, "warnings": warnings, "incomplete": scenes.incomplete(identifier)}
                        del payload
                        memory.release()
                    elif request["operation"] == "render":
                        progress("Preparing render", 0, None)
                        identifier = request["sceneId"]
                        if not scenes.exists(identifier):
                            raise SceneError("Unknown scene; send it again")
                        if engine is None:
                            engine = renderer.Renderer()
                        settings = schema.normalize(request.get("settings"))
                        size, aa = request["size"], request["aa"]
                        key = (identifier, json.dumps(settings, sort_keys=True), size, aa)
                        pixels = render_cache.get(key)
                        render_steps = [0]
                        def render_progress(stage, completed, total):
                            # Capture the render's total for the final image-writing step.
                            progress(stage, completed, total + 1)
                            render_steps[0] = total
                        if pixels is None:
                            model = engine.load(scenes.path(identifier))
                            pixels = engine.render(model, settings, size, aa, progress=render_progress)
                            render_cache.put(key, pixels)
                        progress("Saving image", render_steps[0], render_steps[0] + 1)
                        if request["format"] == "png":
                            renderer.save_png_pixels(pixels, directory / "render.png")
                        else:
                            (directory / "render.rgba").write_bytes(renderer.to_rgba8_top_down(pixels))
                        # Exports are large one-offs; return temporary buffers afterwards.
                        del pixels
                        result = {"textBounds": engine.text_bounds(settings, size, aa)} if request.get("textBounds") else {}
                        memory.release()
                        progress("Image ready", render_steps[0] + 1, render_steps[0] + 1)
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
