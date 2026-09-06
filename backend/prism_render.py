"""Prism's Blender worker, adapted for an interactive local render workflow.

This program is distributed under GPL-3.0-or-later. It is intentionally small:
Prism sends a source model and JSON settings, then Blender imports the model
into a clean Eevee studio scene and writes one image.
"""
import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Vector


def arguments():
    args = sys.argv
    return args[args.index("--") + 1 :] if "--" in args else []


def import_model(path):
    extension = os.path.splitext(path)[1].lower()
    if extension == ".blend":
        with bpy.data.libraries.load(path, link=False) as library:
            objects = list(library.objects)
        for object in objects:
            if object is not None:
                bpy.context.collection.objects.link(object)
        return
    operator = {
        ".obj": bpy.ops.wm.obj_import,
        ".fbx": bpy.ops.import_scene.fbx,
        ".glb": bpy.ops.import_scene.gltf,
        ".gltf": bpy.ops.import_scene.gltf,
        ".stl": bpy.ops.wm.stl_import,
        ".dae": bpy.ops.wm.collada_import,
        ".ply": bpy.ops.wm.ply_import,
        ".abc": bpy.ops.wm.alembic_import,
        ".usd": bpy.ops.wm.usd_import,
        ".usda": bpy.ops.wm.usd_import,
        ".usdc": bpy.ops.wm.usd_import,
        ".usdz": bpy.ops.wm.usd_import,
    }.get(extension)
    if operator is None:
        raise RuntimeError(f"No Prism importer is configured for {extension}.")
    operator(filepath=path)


def bounds(objects):
    points = [object.matrix_world @ Vector(corner) for object in objects for corner in object.bound_box]
    low = Vector((min(point.x for point in points), min(point.y for point in points), min(point.z for point in points)))
    high = Vector((max(point.x for point in points), max(point.y for point in points), max(point.z for point in points)))
    return (low + high) / 2, max((high - low).length, 0.01)


def look_at(object, target):
    object.rotation_euler = (Vector(target) - object.location).to_track_quat("-Z", "Y").to_euler()


def light(name, location, energy, size, target):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    object = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(object)
    object.location = location
    look_at(object, target)


def apply_cavity(meshes, strength, diameter):
    """Add Eevee's ambient-occlusion shader to simple Principled materials.

    Workbench's cavity option is unavailable to an Eevee render. This keeps the
    control useful in the final image without replacing imported materials.
    Linked base colours are left alone because Prism must not break a model's
    existing material graph.
    """
    for mesh in meshes:
        for slot in mesh.material_slots:
            material = slot.material
            if material is None or not material.use_nodes:
                continue
            nodes = material.node_tree.nodes
            links = material.node_tree.links
            principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
            if principled is None:
                continue
            base = principled.inputs.get("Base Color")
            if base is None or base.is_linked:
                continue
            ambient = nodes.new("ShaderNodeAmbientOcclusion")
            ambient.inputs["Distance"].default_value = max(diameter * 0.12, 0.001)
            mix = nodes.new("ShaderNodeMixRGB")
            mix.blend_type = "MULTIPLY"
            mix.inputs[0].default_value = strength
            mix.inputs[2].default_value = base.default_value
            links.new(ambient.outputs["Color"], mix.inputs[1])
            links.new(mix.outputs["Color"], base)


def render(source, output, settings):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    import_model(source)
    meshes = [object for object in bpy.context.scene.objects if object.type == "MESH"]
    if not meshes:
        raise RuntimeError("The source did not produce any mesh objects.")
    centre, diameter = bounds(meshes)
    if settings.get("cavity", True):
        apply_cavity(meshes, float(settings.get("cavityStrength", 0.65)), diameter)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = int(settings.get("width", 1024))
    scene.render.resolution_y = int(settings.get("height", 1024))
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = settings.get("format", "PNG")
    scene.render.image_settings.color_mode = "RGBA" if settings.get("transparent", False) else "RGB"
    scene.render.film_transparent = bool(settings.get("transparent", False))
    scene.render.filepath = output
    scene.world.color = tuple(settings.get("background", [0.055, 0.063, 0.086]))

    camera_data = bpy.data.cameras.new("Prism Camera")
    camera_data.lens = float(settings.get("focalLength", 55))
    camera = bpy.data.objects.new("Prism Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    scene.camera = camera
    orbit = settings.get("orbit", [35, 25])
    yaw, pitch = math.radians(float(orbit[0])), math.radians(float(orbit[1]))
    distance = diameter * float(settings.get("framing", 1.45))
    camera.location = centre + Vector((distance * math.cos(pitch) * math.cos(yaw), distance * math.cos(pitch) * math.sin(yaw), distance * math.sin(pitch)))
    look_at(camera, centre)

    strength = float(settings.get("keyStrength", 1100))
    light("Key", centre + Vector((diameter, -diameter, diameter * 1.4)), strength, diameter, centre)
    light("Fill", centre + Vector((-diameter, -diameter * .4, diameter * .4)), float(settings.get("fillStrength", 260)), diameter * 1.5, centre)
    scene.world.color = tuple(settings.get("background", [0.055, 0.063, 0.086]))
    scene.world.color = tuple(channel * float(settings.get("worldStrength", 1)) for channel in scene.world.color)
    scene.render.filepath = output
    bpy.ops.render.render(write_still=True)


parser = argparse.ArgumentParser()
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--settings", required=True)
params = parser.parse_args(arguments())
with open(params.settings, "r", encoding="utf8") as file:
    render(params.input, params.output, json.load(file))
