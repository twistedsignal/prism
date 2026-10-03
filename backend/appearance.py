"""Bake classic clothing and face decals into a six-face texture atlas."""

import base64

import numpy as np

# Pixel rectangles from Roblox's official 585 x 559 classic clothing template.
# Faces use Roblox NormalId names and image coordinates start at the top left.
RECTS = {
    "torso": {
        "Front": (231, 74, 128, 128),
        "Back": (427, 74, 128, 128),
        "Right": (165, 74, 64, 128),
        "Left": (361, 74, 64, 128),
        "Top": (231, 8, 128, 64),
        "Bottom": (231, 204, 128, 64),
    },
    "right": {
        "Front": (217, 355, 64, 128),
        "Back": (85, 355, 64, 128),
        "Right": (151, 355, 64, 128),
        "Left": (19, 355, 64, 128),
        "Top": (217, 289, 64, 64),
        "Bottom": (217, 485, 64, 64),
    },
    "left": {
        "Front": (308, 355, 64, 128),
        "Back": (440, 355, 64, 128),
        "Right": (506, 355, 64, 128),
        "Left": (374, 355, 64, 128),
        "Top": (308, 289, 64, 64),
        "Bottom": (308, 485, 64, 64),
    },
}
FACES = ("Right", "Left", "Top", "Bottom", "Back", "Front")
TILE = 256
PAD = 2


def project(points, face, size):
    p = np.asarray(points, dtype=np.float64) / np.maximum(size, 1e-6)
    x, y, z = p.T
    if face == "Front":
        return np.column_stack((0.5 - x, 0.5 - y))
    if face == "Back":
        return np.column_stack((0.5 + x, 0.5 - y))
    if face == "Right":
        return np.column_stack((0.5 + z, 0.5 - y))
    if face == "Left":
        return np.column_stack((0.5 - z, 0.5 - y))
    return np.column_stack((0.5 - x, 0.5 + z if face == "Top" else 0.5 - z))


def sample(image, uv, repeat=False):
    uv = np.mod(uv, 1) if repeat else np.clip(uv, 0, 1)
    x = np.minimum((uv[..., 0] * image.shape[1]).astype(int), image.shape[1] - 1)
    y = np.minimum((uv[..., 1] * image.shape[0]).astype(int), image.shape[0] - 1)
    return image[y, x]


def over(background, foreground):
    alpha = foreground[..., 3:4]
    out_alpha = alpha + background[..., 3:4] * (1 - alpha)
    rgb = foreground[..., :3] * alpha + background[..., :3] * background[..., 3:4] * (
        1 - alpha
    )
    return np.concatenate((rgb / np.maximum(out_alpha, 1e-8), out_alpha), axis=-1)


def image_of(reference, textures):
    from scene import decode_texture

    width, height, pixels = decode_texture(textures[reference["id"]])
    return (
        np.frombuffer(pixels, dtype=np.uint8)
        .reshape(height, width, 4)
        .astype(np.float32)
        / 255
    )


def bake(corners, size, rgb, base, layers, textures):
    """Preserve geometry and normals; replace UVs with baked part-local projections."""
    from scene import face_normal

    tiles = np.empty((6, TILE, TILE, 4), dtype=np.float32)
    tiles[:] = (*rgb, 0 if base and base.get("mode") == "alpha" else 1)
    points = np.asarray([corner[0] for corner in corners])
    projection_size = np.maximum(np.ptp(points, axis=0), 1e-6)
    projection_center = (points.min(axis=0) + points.max(axis=0)) / 2
    original_uvs = np.asarray([(uv[0], 1 - uv[1]) for _, uv, _ in corners])
    projected = np.empty((len(corners), 2))
    face_indices = []
    base_image = (
        image_of(base, textures) if base and base.get("id") in textures else None
    )
    for start in range(0, len(corners), 3):
        normal = np.mean([corner[2] for corner in corners[start : start + 3]], axis=0)
        if np.linalg.norm(normal) < 1e-8:
            normal = face_normal(*points[start : start + 3])
        axis = int(np.argmax(np.abs(normal)))
        index = axis * 2 + (0 if normal[axis] > 0 else 1)
        # Axis Z uses Back then Front.
        face_indices.extend([index] * 3)
        uv = np.clip(
            project(
                points[start : start + 3] - projection_center,
                FACES[index],
                projection_size,
            ),
            0,
            1,
        )
        projected[start : start + 3] = uv
        if base_image is None:
            continue
        # Rasterize the original mesh UVs onto the projected face, retaining painted body maps.
        triangle = uv * (TILE - 1)
        lo = np.maximum(np.floor(triangle.min(axis=0)).astype(int), 0)
        hi = np.minimum(np.ceil(triangle.max(axis=0)).astype(int), TILE - 1)
        a, b, c = triangle
        determinant = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(determinant) < 1e-8:
            continue
        yy, xx = np.mgrid[lo[1] : hi[1] + 1, lo[0] : hi[0] + 1]
        w0 = ((b[1] - c[1]) * (xx - c[0]) + (c[0] - b[0]) * (yy - c[1])) / determinant
        w1 = ((c[1] - a[1]) * (xx - c[0]) + (a[0] - c[0]) * (yy - c[1])) / determinant
        weights = np.stack((w0, w1, 1 - w0 - w1), axis=-1)
        inside = np.all(weights >= -1e-5, axis=-1)
        texels = sample(
            base_image, weights @ original_uvs[start : start + 3], repeat=True
        )
        target = tiles[index, lo[1] : hi[1] + 1, lo[0] : hi[0] + 1]
        composite = over(target, texels) if base.get("mode") != "alpha" else texels
        target[inside] = composite[inside]
    yy, xx = np.mgrid[0:TILE, 0:TILE]
    face_uv = np.stack((xx, yy), axis=-1) / (TILE - 1)
    for layer in layers:
        if layer.get("id") not in textures:
            continue
        image = image_of(layer, textures)
        for index, face in enumerate(FACES):
            if layer.get("face") and layer["face"] != face:
                continue
            region = layer.get("region")
            uv = face_uv.copy()
            if region:
                if region not in RECTS:
                    raise ValueError("Unknown clothing template region")
                low, high = layer.get("range", [0, 1])
                if face not in ("Top", "Bottom"):
                    uv[..., 1] = low + uv[..., 1] * (high - low)
                x, y, width, height = RECTS[region][face]
                uv = (uv * (width - 1, height - 1) + (x + 0.5, y + 0.5)) / (585, 559)
            elif layer.get("graphic"):
                low, high = layer.get("range", [0, 1])
                uv[..., 1] = low + uv[..., 1] * (high - low)
            elif layer.get("repeat"):
                # Texture tiles are authored in studs, not fractions of the face.
                dimensions = {
                    "Front": size[:2],
                    "Back": size[:2],
                    "Left": [size[2], size[1]],
                    "Right": [size[2], size[1]],
                    "Top": [size[0], size[2]],
                    "Bottom": [size[0], size[2]],
                }[face]
                repeat = np.maximum(layer["repeat"], 1e-6)
                uv = (uv * dimensions + layer.get("offset", [0, 0])) / repeat
            foreground = sample(image, uv, repeat=bool(layer.get("repeat"))).copy()
            foreground[..., :3] *= layer.get("tint", [1, 1, 1])
            foreground[..., 3] *= 1 - layer.get("transparency", 0)
            tiles[index] = over(tiles[index], foreground)
    stride = TILE + 2 * PAD
    atlas = np.zeros((2 * stride, 3 * stride, 4), dtype=np.float32)
    for index, tile in enumerate(tiles):
        x, y = index % 3 * stride, index // 3 * stride
        atlas[y : y + stride, x : x + stride] = np.pad(
            tile, ((PAD, PAD), (PAD, PAD), (0, 0)), mode="edge"
        )
    result = []
    for (point, _, normal), uv, index in zip(corners, projected, face_indices):
        x, y = index % 3 * stride + PAD, index // 3 * stride + PAD
        u, v = (uv * (TILE - 1) + (x + 0.5, y + 0.5)) / (3 * stride, 2 * stride)
        result.append((point, (float(u), float(1 - v)), normal))
    pixels = (np.clip(atlas, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes()
    return result, {
        "width": 3 * stride,
        "height": 2 * stride,
        "pixels": base64.b64encode(pixels).decode("ascii"),
    }
