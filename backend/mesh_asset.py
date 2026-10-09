"""Roblox FileMesh decoding into the triangle-corner buffers used by scene.py."""

import base64
import ctypes as ct
import math
import re
import struct
import sys
from array import array
from itertools import pairwise

MAX_VERTICES = 2_000_000
MAX_INDICES = 6_000_000


class MeshError(ValueError):
    pass


def require_bytes(data, offset, length):
    if offset < 0 or length < 0 or offset + length > len(data):
        raise MeshError("Truncated mesh data")


def counts(vertices, indices):
    if (
        not 0 < vertices <= MAX_VERTICES
        or not 0 < indices <= MAX_INDICES
        or indices % 3
    ):
        raise MeshError("Invalid mesh vertex or triangle count")


def packed(values):
    values = array("f", values)
    if any(not math.isfinite(v) for v in values):
        raise MeshError("Mesh contains non-finite attributes")
    if sys.byteorder != "little":
        values.byteswap()
    return base64.b64encode(values.tobytes()).decode("ascii")


def expand(vertices, normals, uvs, indices):
    counts(len(vertices), len(indices))
    if any(i >= len(vertices) or i < 0 for i in indices):
        raise MeshError("Mesh face references an invalid vertex")
    return {
        "positions": packed(v for i in indices for v in vertices[i]),
        "normals": packed(v for i in indices for v in normals[i]) if normals else None,
        "uvs": packed(v for i in indices for v in uvs[i]) if uvs else None,
    }


def lod0_range(lods, face_count):
    """The faces of the highest detail level; later levels are coarser copies of the same model."""
    if len(lods) < 2:
        return 0, face_count
    if any(a > b for a, b in pairwise(lods)) or lods[-1] > face_count:
        raise MeshError("Invalid mesh LOD ranges")
    return tuple(lods[:2]) if lods[1] > lods[0] else (0, face_count)


def binary_mesh(data, offset, version):
    require_bytes(data, offset, 12)
    if version == "2.00":
        header, stride, face_stride, vertex_count, face_count = struct.unpack_from(
            "<HBBII", data, offset
        )
        if header != 12 or stride not in (36, 40) or face_stride != 12:
            raise MeshError("Unsupported v2 mesh header")
        lod_count = bones = 0
    elif version in ("3.00", "3.01"):
        require_bytes(data, offset, 16)
        header, stride, face_stride, lod_stride, lod_count, vertex_count, face_count = (
            struct.unpack_from("<HBBHHII", data, offset)
        )
        if (
            header != 16
            or stride not in (36, 40)
            or face_stride != 12
            or lod_stride != 4
        ):
            raise MeshError("Unsupported v3 mesh header")
        bones = 0
    else:
        require_bytes(data, offset, 24)
        header, _, vertex_count, face_count, lod_count, bones, _, _, _ = (
            struct.unpack_from("<HHIIHHIHH", data, offset)
        )
        if header != 24:
            raise MeshError("Unsupported v4 mesh header")
        stride = 40
    counts(vertex_count, face_count * 3)
    offset += header
    require_bytes(data, offset, vertex_count * stride)
    vertices, normals, uvs = [], [], []
    for i in range(vertex_count):
        values = struct.unpack_from("<8f", data, offset + i * stride)
        vertices.append(values[:3])
        normals.append(values[3:6])
        uvs.append(values[6:8])
    offset += vertex_count * stride + (vertex_count * 8 if bones else 0)
    require_bytes(data, offset, face_count * 12 + lod_count * 4)
    start, end = lod0_range(struct.unpack_from(f"<{lod_count}I", data, offset + face_count * 12), face_count)
    indices = struct.unpack_from(f"<{(end - start) * 3}I", data, offset + start * 12)
    return expand(vertices, normals, uvs, indices)


def draco_mesh(stream, lods=()):
    # Use Blender's own platform-aware library discovery, including portable builds.
    try:
        import io_scene_gltf2  # noqa: F401

        try:
            from io_scene_gltf2.io.com import library
        except ImportError:
            library = None

        if library is not None and hasattr(library, "dll_path"):
            path = library.dll_path("bf_intern_draco_bridge", "Draco")
        else:
            from io_scene_gltf2.io.com.gltf2_io_draco_compression_extension import (
                dll_path,
            )

            path = dll_path()
        if path is None:
            raise MeshError("Blender's bundled Draco decoder is unavailable")
        dll = ct.CDLL(str(path))
    except (ImportError, OSError, AttributeError) as error:
        raise MeshError(
            "Blender's bundled Draco decoder is unavailable; use an official Blender build"
        ) from error
    signatures = {
        "decoderCreate": (ct.c_void_p, []),
        "decoderRelease": (None, [ct.c_void_p]),
        "decoderDecode": (ct.c_bool, [ct.c_void_p, ct.c_void_p, ct.c_size_t]),
        "decoderGetVertexCount": (ct.c_uint32, [ct.c_void_p]),
        "decoderGetIndexCount": (ct.c_uint32, [ct.c_void_p]),
        "decoderReadAttribute": (
            ct.c_bool,
            [ct.c_void_p, ct.c_uint32, ct.c_size_t, ct.c_char_p],
        ),
        "decoderGetAttributeByteLength": (ct.c_size_t, [ct.c_void_p, ct.c_uint32]),
        "decoderCopyAttribute": (None, [ct.c_void_p, ct.c_uint32, ct.c_void_p]),
        "decoderReadIndices": (ct.c_bool, [ct.c_void_p, ct.c_size_t]),
        "decoderGetIndicesByteLength": (ct.c_size_t, [ct.c_void_p]),
        "decoderCopyIndices": (None, [ct.c_void_p, ct.c_void_p]),
    }
    try:
        for name, (result, args) in signatures.items():
            function = getattr(dll, name)
            function.restype = result
            function.argtypes = args
    except AttributeError as error:
        raise MeshError("Incompatible Blender Draco decoder") from error
    decoder = dll.decoderCreate()
    if not decoder:
        raise MeshError("Could not allocate Draco decoder")
    try:
        buffer = ct.create_string_buffer(stream)
        if not dll.decoderDecode(decoder, buffer, len(stream)):
            raise MeshError("Invalid Draco mesh")
        vertex_count, index_count = (
            dll.decoderGetVertexCount(decoder),
            dll.decoderGetIndexCount(decoder),
        )
        counts(vertex_count, index_count)

        def attribute(aid, width, required=False):
            if not dll.decoderReadAttribute(decoder, aid, 5126, f"VEC{width}".encode()):
                if required:
                    raise MeshError("Draco mesh has no positions")
                return None
            length = dll.decoderGetAttributeByteLength(decoder, aid)
            if length != vertex_count * width * 4:
                raise MeshError("Invalid Draco attribute length")
            target = ct.create_string_buffer(length)
            dll.decoderCopyAttribute(decoder, aid, target)
            return list(struct.iter_unpack(f"<{width}f", target.raw))

        vertices = attribute(0, 3, True)
        normals, uvs = attribute(1, 3), attribute(2, 2)
        if not dll.decoderReadIndices(decoder, 5125):
            raise MeshError("Could not decode Draco indices")
        if dll.decoderGetIndicesByteLength(decoder) != index_count * 4:
            raise MeshError("Invalid Draco index length")
        target = ct.create_string_buffer(index_count * 4)
        dll.decoderCopyIndices(decoder, target)
        start, end = lod0_range(lods, index_count // 3)
        indices = struct.unpack(f"<{index_count}I", target.raw)[start * 3 : end * 3]
        return expand(vertices, normals, uvs, indices)
    finally:
        dll.decoderRelease(decoder)


def decode(data):
    newline = data.find(b"\n", 0, 32)
    if newline < 0 or not data.startswith(b"version "):
        raise MeshError("Not a Roblox mesh file")
    version = data[8:newline].decode("ascii", errors="replace").strip()
    offset = newline + 1
    if version in ("1.00", "1.01"):
        try:
            face_line, vectors = data[offset:].split(b"\n", 1)
            face_count = int(face_line)
            counts(face_count * 3, face_count * 3)
            groups = re.findall(rb"\[([^\]]+)\]", vectors)
            if len(groups) != face_count * 9:
                raise MeshError("Invalid v1 mesh corner count")
            vertices, normals, uvs = [], [], []
            for i in range(0, len(groups), 3):
                attributes = [
                    tuple(float(x) for x in group.split(b","))
                    for group in groups[i : i + 3]
                ]
                if any(len(a) != 3 for a in attributes):
                    raise MeshError("Invalid v1 mesh vector")
                vertices.append(
                    tuple(v * (0.5 if version == "1.00" else 1) for v in attributes[0])
                )
                normals.append(attributes[1])
                # ASCII FileMesh v1 uses bottom-left UVs. Normalize to the
                # top-left convention used by EditableMesh and binary FileMesh.
                uvs.append((attributes[2][0], 1.0 - attributes[2][1]))
            return expand(vertices, normals, uvs, list(range(face_count * 3)))
        except ValueError as error:
            raise MeshError("Invalid v1 mesh data") from error
    if version in ("2.00", "3.00", "3.01", "4.00", "4.01"):
        return binary_mesh(data, offset, version)
    if version != "7.00":
        raise MeshError(f"Unsupported Roblox mesh format {version}")
    core, lods = None, ()
    while offset < len(data):
        require_bytes(data, offset, 16)
        kind, revision, size = struct.unpack_from("<8sII", data, offset)
        offset += 16
        require_bytes(data, offset, size)
        if kind == b"COREMESH":
            if revision != 2 or core is not None:
                raise MeshError("Unsupported v7 core mesh")
            require_bytes(data, offset, 4)
            (length,) = struct.unpack_from("<I", data, offset)
            if length != size - 4:
                raise MeshError("Invalid Draco stream length")
            core = data[offset + 4 : offset + size]
        elif kind == b"LODS\0\0\0\0" and revision == 1 and size >= 7:
            # Lower detail levels follow the full mesh in the same buffer; drawing them overlaps it.
            _, _, count = struct.unpack_from("<HBI", data, offset)
            if 7 + count * 4 > size:
                raise MeshError("Invalid v7 LOD chunk")
            lods = struct.unpack_from(f"<{count}I", data, offset + 7)
        offset += size
    if core is None:
        raise MeshError("v7 mesh has no core geometry")
    return draco_mesh(core, lods)
