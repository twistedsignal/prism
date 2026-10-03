"""Bake classic clothing and face decals into a six-face texture atlas."""

import base64
from functools import lru_cache
from pathlib import Path

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


def sample_linear(image, uv):
    """Bilinear sampling at texture pixel centers, with clamped edges."""
    coords = np.clip(uv, 0, 1) * [image.shape[1], image.shape[0]] - 0.5
    low = np.floor(coords).astype(int)
    weight = (coords - low).astype(np.float32)
    x0 = np.clip(low[..., 0], 0, image.shape[1] - 1)
    y0 = np.clip(low[..., 1], 0, image.shape[0] - 1)
    x1 = np.clip(low[..., 0] + 1, 0, image.shape[1] - 1)
    y1 = np.clip(low[..., 1] + 1, 0, image.shape[0] - 1)
    top = image[y0, x0] * (1 - weight[..., 0:1]) + image[y0, x1] * weight[..., 0:1]
    bottom = image[y1, x0] * (1 - weight[..., 0:1]) + image[y1, x1] * weight[..., 0:1]
    return top * (1 - weight[..., 1:2]) + bottom * weight[..., 1:2]


def raster_triangle(points, width, height):
    """Barycentric coverage of a triangle at destination pixel centers."""
    lo = np.maximum(np.floor(points.min(axis=0)).astype(int), 0)
    hi = np.minimum(np.ceil(points.max(axis=0)).astype(int), [width - 1, height - 1])
    a, b, c = points
    determinant = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
    if abs(determinant) < 1e-8 or np.any(hi < lo):
        return None
    yy, xx = np.mgrid[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
    xx, yy = xx + 0.5, yy + 0.5
    w0 = ((b[1] - c[1]) * (xx - c[0]) + (c[0] - b[0]) * (yy - c[1])) / determinant
    w1 = ((c[1] - a[1]) * (xx - c[0]) + (a[0] - c[0]) * (yy - c[1])) / determinant
    weights = np.stack((w0, w1, 1 - w0 - w1), axis=-1)
    return (slice(lo[1], hi[1] + 1), slice(lo[0], hi[0] + 1)), weights, np.all(weights >= -1e-5, axis=-1)


@lru_cache(maxsize=3)
def r15_uv_map(region):
    """Roblox's own compositing mesh maps the clothing template to the body UV atlas."""
    import mesh_asset

    if region not in RECTS:
        raise ValueError("Unknown clothing template region")
    width, height = (388, 272) if region == "torso" else (264, 284)
    mesh = mesh_asset.decode((Path(__file__).parent / "clothing" / f"{region}.mesh").read_bytes())
    points = np.frombuffer(base64.b64decode(mesh["positions"]), dtype="<f4").reshape(-1, 3, 3)[..., :2].copy()
    points[..., 1] = height - points[..., 1]
    uvs = np.frombuffer(base64.b64decode(mesh["uvs"]), dtype="<f4").reshape(-1, 3, 2)
    mapping = np.zeros((height, width, 2), dtype=np.float32)
    valid = np.zeros((height, width), dtype=bool)
    for triangle, uv in zip(points, uvs):
        raster = raster_triangle(triangle, width, height)
        if raster is None:
            continue
        window, weights, inside = raster
        mapping[window][inside] = (weights @ uv)[inside]
        valid[window][inside] = True
    return mapping, valid


def bake_r15(corners, size, rgb, base, layers, textures, region):
    """Keep the original body UVs, including every wrist/knee/ankle joint island."""
    mapping, valid = r15_uv_map(region)
    height, width = valid.shape
    atlas = np.empty((height, width, 4), dtype=np.float32)
    atlas[:] = (*rgb, 0 if base and base.get("mode") == "alpha" else 1)
    yy, xx = np.mgrid[:height, :width]
    body_uv = np.stack(((xx + 0.5) / width, (yy + 0.5) / height), axis=-1)
    if base and base.get("id") in textures:
        painted = sample_linear(image_of(base, textures), body_uv)
        atlas = painted if base.get("mode") == "alpha" else over(atlas, painted)

    def tinted(image, layer):
        image[..., :3] *= layer.get("tint", [1, 1, 1])
        image[..., 3] *= 1 - layer.get("transparency", 0)
        return image

    points = np.asarray([corner[0] for corner in corners])
    projection_size = np.maximum(np.ptp(points, axis=0), 1e-6)
    center = (points.min(axis=0) + points.max(axis=0)) / 2
    original_uv = np.asarray([(uv[0], 1 - uv[1]) for _, uv, _ in corners])
    for layer in layers:
        if layer.get("id") not in textures:
            continue
        image = image_of(layer, textures)
        if layer.get("r15") and layer.get("region"):
            foreground = sample_linear(image, mapping)
            foreground[..., 3] *= valid
            atlas = over(atlas, tinted(foreground, layer))
        elif layer.get("r15") and layer.get("graphic"):
            # T-shirt graphics occupy the torso's front template rectangle.
            graphic_uv = (mapping * [585, 559] - [231, 74]) / [128, 128]
            foreground = sample_linear(image, graphic_uv)
            foreground[..., 3] *= valid & np.all((graphic_uv >= 0) & (graphic_uv <= 1), axis=-1)
            atlas = over(atlas, tinted(foreground, layer))
        else:
            # Project decals into the existing body UV islands without replacing clothing UVs.
            for start in range(0, len(corners), 3):
                normal = np.mean([corner[2] for corner in corners[start:start + 3]], axis=0)
                axis = int(np.argmax(np.abs(normal)))
                face = FACES[axis * 2 + (0 if normal[axis] > 0 else 1)]
                if layer.get("face") and layer["face"] != face:
                    continue
                raster = raster_triangle(original_uv[start:start + 3] * [width, height], width, height)
                if raster is None:
                    continue
                window, weights, inside = raster
                uv = weights @ project(points[start:start + 3] - center, face, projection_size)
                if layer.get("repeat"):
                    dimensions = size[:2] if face in ("Front", "Back") else (
                        [size[2], size[1]] if face in ("Left", "Right") else [size[0], size[2]]
                    )
                    uv = np.mod((uv * dimensions + layer.get("offset", [0, 0])) / np.maximum(layer["repeat"], 1e-6), 1)
                foreground = tinted(sample_linear(image, uv), layer)
                target = atlas[window]
                target[inside] = over(target, foreground)[inside]
    pixels = (np.clip(atlas, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes()
    return corners, {"width": width, "height": height, "pixels": base64.b64encode(pixels).decode("ascii")}


def bake_colors(corners, colors):
    """Give each distinct triangle color triplet a padded tile, including gradients."""
    palette, triangle_tiles = {}, []
    for start in range(0, len(corners), 3):
        key = tuple(colors[start * 3 : (start + 3) * 3])
        if key not in palette:
            palette[key] = len(palette)
        triangle_tiles.append(palette[key])
    tile = 8
    columns = min(512, max(1, int(np.ceil(np.sqrt(len(palette))))))
    rows = int(np.ceil(len(palette) / columns))
    if rows > 512:
        raise ValueError("Union color atlas exceeds 4096 pixels")
    atlas = np.ones((rows * tile, columns * tile, 4), dtype=np.float32)
    yy, xx = np.mgrid[0:tile, 0:tile]
    weights = np.stack((1 - (xx - 1) / 5 - (yy - 1) / 5,
                        (xx - 1) / 5, (yy - 1) / 5), axis=-1)
    weights = np.maximum(weights, 0)
    weights /= weights.sum(axis=-1, keepdims=True)
    for key, index in palette.items():
        x, y = index % columns * tile, index // columns * tile
        atlas[y:y + tile, x:x + tile, :3] = weights @ np.asarray(key).reshape(3, 3)
    result = []
    triangle_uvs = ((1.5, 1.5), (6.5, 1.5), (1.5, 6.5))
    for i, (point, _, normal) in enumerate(corners):
        index = triangle_tiles[i // 3]
        x, y = triangle_uvs[i % 3]
        u = (index % columns * tile + x) / (columns * tile)
        v = (index // columns * tile + y) / (rows * tile)
        result.append((point, (u, 1 - v), normal))
    pixels = (np.clip(atlas, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes()
    return result, {"width": columns * tile, "height": rows * tile,
                    "pixels": base64.b64encode(pixels).decode("ascii")}


def bake(corners, size, rgb, base, layers, textures, native_uv=False):
    """Preserve geometry and normals; replace UVs with baked part-local projections."""
    from scene import face_normal

    r15 = next((layer for layer in layers if layer.get("r15")), None)
    if native_uv and r15:
        return bake_r15(corners, size, rgb, base, layers, textures, r15.get("region", "torso"))

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
                internal_cap = (face == "Top" and low > 0) or (face == "Bottom" and high < 1)
                if internal_cap:
                    # Interior joints continue the sleeve/pant edge, not the shoulder/hip cap.
                    uv[..., 1] = low if face == "Top" else high
                elif face not in ("Top", "Bottom"):
                    uv[..., 1] = low + uv[..., 1] * (high - low)
                x, y, width, height = RECTS[region]["Front" if internal_cap else face]
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
            if layer.get("multiply"):
                # Built-in material detail modulates stored Union colors.
                tiles[index][..., :3] *= foreground[..., :3] * foreground[..., 3:4] + 1 - foreground[..., 3:4]
            else:
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
