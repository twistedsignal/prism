"""Persistent Blender JSON Lines worker. Run through Blender's --python option."""

from __future__ import annotations

import json
import queue
import sys
import threading
import time
import traceback
import uuid
from math import cos, radians, sin
from pathlib import Path
from typing import Any

import bpy
from mathutils import Vector

PROTOCOL_VERSION = 1
commands: queue.Queue[dict[str, Any]] = queue.Queue()
running = True


def reply(identifier: int, message_type: str, payload: dict[str, Any]) -> None:
    sys.stdout.write(
        json.dumps(
            {"v": PROTOCOL_VERSION, "id": identifier, "type": message_type, "payload": payload}
        )
        + "\n"
    )
    sys.stdout.flush()


def reader() -> None:
    for line in sys.stdin:
        try:
            command = json.loads(line)
            if isinstance(command, dict):
                commands.put(command)
        except json.JSONDecodeError:
            print("Ignoring malformed Prism command.", file=sys.stderr)


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def import_model(path: Path) -> None:
    suffix = path.suffix.lower()
    if suffix == ".obj":
        bpy.ops.wm.obj_import(filepath=str(path))
    elif suffix in {".glb", ".gltf"}:
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    elif suffix == ".stl":
        bpy.ops.wm.stl_import(filepath=str(path))
    elif suffix == ".blend":
        bpy.ops.wm.open_mainfile(filepath=str(path))
    else:
        raise ValueError(f"Unsupported model format: {suffix}")


def mesh_bounds() -> tuple[Vector, Vector]:
    points = [
        object.matrix_world @ Vector(corner)
        for object in bpy.context.scene.objects
        if object.type == "MESH"
        for corner in object.bound_box
    ]
    if not points:
        raise ValueError("The imported file has no renderable mesh objects.")
    return (
        Vector(
            (
                min(point.x for point in points),
                min(point.y for point in points),
                min(point.z for point in points),
            )
        ),
        Vector(
            (
                max(point.x for point in points),
                max(point.y for point in points),
                max(point.z for point in points),
            )
        ),
    )


def prepare_scene() -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = True
    scene.world.color = (0.055, 0.063, 0.086)
    minimum, maximum = mesh_bounds()
    center = (minimum + maximum) * 0.5
    radius = max((maximum - minimum).length * 0.5, 0.1)
    scene["prism_frame_target"] = tuple(center)
    scene["prism_frame_distance"] = radius * 3.2
    camera_data = bpy.data.cameras.new("Prism Camera")
    camera = bpy.data.objects.new("Prism Camera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    camera.location = center + Vector((radius * 1.8, -radius * 1.8, radius * 1.25))
    camera.rotation_euler = (center - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera_data.lens = 50.0
    for name, location, energy in (
        ("Prism Key", (4.0, -4.0, 6.0), 1200.0),
        ("Prism Fill", (-4.0, -2.0, 3.0), 300.0),
    ):
        light_data = bpy.data.lights.new(name, "AREA")
        light_data.energy = energy
        light_data.shape = "DISK"
        light_data.size = radius * 2.0
        light = bpy.data.objects.new(name, light_data)
        scene.collection.objects.link(light)
        light.location = center + Vector(location) * radius
        light.rotation_euler = (center - light.location).to_track_quat("-Z", "Y").to_euler()


def apply_settings(payload: dict[str, Any]) -> None:
    scene = bpy.context.scene
    camera_settings = payload.get("camera")
    if isinstance(camera_settings, dict) and scene.camera is not None:
        target = Vector(
            (
                float(camera_settings.get("target_x", 0.0)),
                float(camera_settings.get("target_y", 0.0)),
                float(camera_settings.get("target_z", 0.0)),
            )
        )
        distance = max(float(camera_settings.get("distance", 4.0)), 0.01)
        yaw, pitch = (
            radians(float(camera_settings.get("yaw_degrees", 35.0))),
            radians(float(camera_settings.get("pitch_degrees", 25.0))),
        )
        position = target + Vector(
            (
                distance * cos(pitch) * cos(yaw),
                distance * cos(pitch) * sin(yaw),
                distance * sin(pitch),
            )
        )
        scene.camera.location = position
        scene.camera.rotation_euler = (target - position).to_track_quat("-Z", "Y").to_euler()
        if camera_settings.get("projection") == "orthographic":
            scene.camera.data.type = "ORTHO"
            scene.camera.data.ortho_scale = float(camera_settings.get("orthographic_scale", 4.0))
        else:
            scene.camera.data.type = "PERSP"
            scene.camera.data.lens = 50.0
    output = payload.get("output")
    if isinstance(output, dict):
        scene.render.film_transparent = bool(output.get("transparent_background", False))
        if output.get("engine") == "cycles":
            scene.render.engine = "CYCLES"
            scene.cycles.samples = 64
        else:
            scene.render.engine = "BLENDER_EEVEE"
    lighting = payload.get("lighting")
    if isinstance(lighting, dict):
        key = bpy.data.lights.get("Prism Key")
        fill = bpy.data.lights.get("Prism Fill")
        if key is not None:
            key.energy = float(lighting.get("key_energy", 1100.0))
        if fill is not None:
            fill.energy = float(lighting.get("fill_energy", 260.0))
        scene.world.color = (float(lighting.get("world_strength", 1.0)),) * 3
    material = payload.get("material")
    if isinstance(material, dict) and material.get("use_original") is False:
        override = bpy.data.materials.get("Prism Override") or bpy.data.materials.new(
            "Prism Override"
        )
        override.diffuse_color = (0.8, 0.8, 0.8, 1.0)
        override.metallic = float(material.get("metallic", 0.0))
        override.roughness = float(material.get("roughness", 0.45))
        for object in scene.objects:
            if object.type == "MESH":
                object.data.materials.clear()
                object.data.materials.append(override)
    geometry = payload.get("geometry")
    if isinstance(geometry, dict):
        for object in scene.objects:
            if object.type != "MESH":
                continue
            for polygon in object.data.polygons:
                polygon.use_smooth = bool(geometry.get("smooth_shading", True))
            level = int(geometry.get("subdivision_level", 0))
            modifier = object.modifiers.get("Prism Subdivision")
            if level > 0:
                if modifier is None:
                    modifier = object.modifiers.new("Prism Subdivision", "SUBSURF")
                modifier.levels = level
                modifier.render_levels = level
            elif modifier is not None:
                object.modifiers.remove(modifier)
    cavity = payload.get("cavity")
    if isinstance(cavity, dict):
        light_settings = scene.world.light_settings
        if bool(cavity.get("enabled", True)):
            light_settings.ao_factor = float(
                cavity.get("ambient_occlusion", cavity.get("valley_strength", 0.5))
            )
            light_settings.distance = max(float(cavity.get("distance", 0.5)), 0.01)
        else:
            light_settings.ao_factor = 0.0


def render_image(payload: dict[str, Any], preview: bool) -> Path:
    scene = bpy.context.scene
    apply_settings(payload)
    if preview:
        scene.render.engine = "BLENDER_EEVEE"
    output = payload.get("output", {})
    if not isinstance(output, dict):
        output = {}
    default_size = 512 if preview else 1024
    width = int(output.get("width", default_size))
    height = int(output.get("height", default_size))
    scene.render.resolution_x = max(1, min(width, 16384))
    scene.render.resolution_y = max(1, min(height, 16384))
    scene.render.resolution_percentage = 100
    if preview:
        path = Path(bpy.app.tempdir) / f"prism-preview-{uuid.uuid4().hex}.png"
    else:
        path = Path(str(payload["output_path"])).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        formats = {
            ".png": "PNG",
            ".jpg": "JPEG",
            ".jpeg": "JPEG",
            ".webp": "WEBP",
            ".exr": "OPEN_EXR",
        }
        file_format = formats.get(path.suffix.lower())
        if file_format is None:
            raise ValueError("Prism exports PNG, JPEG, WebP, and EXR files.")
        scene.render.image_settings.file_format = file_format
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    return path


def handle(command: dict[str, Any]) -> None:
    global running
    identifier = command.get("id")
    message_type = command.get("type")
    payload = command.get("payload")
    if (
        not isinstance(identifier, int)
        or not isinstance(message_type, str)
        or not isinstance(payload, dict)
    ):
        return
    try:
        if message_type == "worker.hello":
            reply(identifier, "worker.ready", {"blender_version": bpy.app.version_string})
        elif message_type == "worker.shutdown":
            reply(identifier, "worker.stopped", {})
            running = False
            bpy.ops.wm.quit_blender()
        elif message_type == "model.import":
            model_path = Path(str(payload["path"])).expanduser()
            if not model_path.is_file():
                raise ValueError("The selected model file does not exist.")
            clear_scene()
            import_model(model_path)
            prepare_scene()
            reply(
                identifier,
                "model.imported",
                {
                    "path": str(model_path),
                    "frame_target": list(bpy.context.scene["prism_frame_target"]),
                    "frame_distance": bpy.context.scene["prism_frame_distance"],
                },
            )
        elif message_type == "camera.frame":
            scene = bpy.context.scene
            reply(
                identifier,
                "camera.framed",
                {
                    "frame_target": list(scene["prism_frame_target"]),
                    "frame_distance": scene["prism_frame_distance"],
                },
            )
        elif message_type == "preview.render":
            frame = render_image(payload, preview=True)
            reply(
                identifier,
                "preview.frame",
                {
                    "transport": "png-path",
                    "path": str(frame),
                    "generation": payload.get("generation", 0),
                },
            )
        elif message_type == "output.render":
            output_path = render_image(payload, preview=False)
            reply(identifier, "output.rendered", {"path": str(output_path)})
        else:
            reply(
                identifier,
                f"{message_type}.error",
                {"code": "unsupported_command", "message": "Command is not implemented."},
            )
    except (KeyError, RuntimeError, TypeError, ValueError) as error:
        print(traceback.format_exc(), file=sys.stderr)
        reply(identifier, f"{message_type}.error", {"code": "worker_error", "message": str(error)})


def drain_commands() -> None:
    while not commands.empty():
        handle(commands.get_nowait())


threading.Thread(target=reader, daemon=True).start()
while running:
    drain_commands()
    time.sleep(0.05)
