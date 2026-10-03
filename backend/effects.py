"""Display-space image effects, independent of Blender."""

import math
from functools import lru_cache

import numpy as np

import schema

REFERENCE_RESOLUTION = 512
EFFECT_KEYS = frozenset({
    "saturation", "contrast", "brightness", "outlineColor", "outlineSize",
    "dropShadow", "shadowColor", "shadowOpacity", "shadowBlur", "shadowOffsetX", "shadowOffsetY",
    "glow", "glowColor", "glowSize", "glowOpacity",
})


def shift_mask(mask, dx, dy):
    """Translate an alpha mask without wrapping pixels at image edges."""
    height, width = mask.shape
    shifted = np.zeros_like(mask)
    if abs(dx) >= width or abs(dy) >= height:
        return shifted
    source_x, source_y = max(0, -dx), max(0, -dy)
    target_x, target_y = max(0, dx), max(0, dy)
    copy_width, copy_height = width - abs(dx), height - abs(dy)
    shifted[target_y:target_y + copy_height, target_x:target_x + copy_width] = (
        mask[source_y:source_y + copy_height, source_x:source_x + copy_width]
    )
    return shifted


def horizontal_max(mask, radius):
    """Sliding maximum in linear time using block prefix/suffix maxima."""
    if radius == 0:
        return mask
    height, width = mask.shape
    window = 2 * radius + 1
    length = width + 2 * radius
    padded = np.pad(mask, ((0, 0), (radius, radius + (-length % window))))
    blocks = padded.reshape(height, -1, window)
    prefix = np.maximum.accumulate(blocks, axis=2).reshape(height, -1)
    suffix = np.maximum.accumulate(blocks[..., ::-1], axis=2)[..., ::-1].reshape(height, -1)
    return np.maximum(suffix[:, :width], prefix[:, window - 1:window - 1 + width])


@lru_cache(maxsize=128)
def fft_length(minimum):
    """Smallest FFT length whose prime factors are 2, 3 and 5."""
    best = 1 << (minimum - 1).bit_length()
    a = 1
    while a < best:
        b = a
        while b < best:
            c = b
            while c < minimum:
                c *= 5
            best = min(best, c)
            b *= 3
        a *= 2
    return best


@lru_cache(maxsize=4)
def disk_spectrum(radius, height, width):
    y, x = np.mgrid[-radius:radius + 1, -radius:radius + 1]
    disk = (x * x + y * y <= radius * radius).astype(np.float32)
    shape = (fft_length(height + 2 * radius), fft_length(width + 2 * radius))
    return np.fft.rfft2(disk, s=shape), shape


def binary_dilation(mask, radius):
    kernel, shape = disk_spectrum(radius, *mask.shape)
    frequencies = np.fft.rfft2(mask.astype(np.float32), s=shape)
    frequencies *= kernel
    count = np.fft.irfft2(frequencies, s=shape)
    h, w = mask.shape
    return count[radius:radius + h, radius:radius + w] > 0.5


def opaque_dilation(mask, radius):
    """Accelerate opaque silhouettes; resolve their AA fringe exactly."""
    opaque = mask == 1
    if not np.any(opaque):
        return None
    soft = (mask > 0) & ~opaque
    if np.count_nonzero(soft) > mask.size // 10:
        return None
    expanded = binary_dilation(opaque, radius)
    if not np.any(soft):
        return expanded.astype(mask.dtype)
    fringe = binary_dilation(mask > 0, radius) & ~expanded
    y, x = np.nonzero(fringe)
    # Highly fragmented/translucent models use the general sliding maximum.
    if len(y) * radius > mask.size:
        return None
    result = expanded.astype(mask.dtype)
    ky, kx = np.mgrid[-radius:radius + 1, -radius:radius + 1]
    inside = kx * kx + ky * ky <= radius * radius
    ky, kx = ky[inside] + radius, kx[inside] + radius
    padded = np.pad(mask, radius)
    for start in range(0, len(y), 256):
        ys, xs = y[start:start + 256], x[start:start + 256]
        result[ys, xs] = padded[ys[:, None] + ky, xs[:, None] + kx].max(axis=1)
    return result


def dilate_mask(mask, radius):
    """Exact disk dilation without allocating one full image per kernel pixel."""
    if radius <= 0:
        return mask.copy()
    if radius >= 3:
        fast = opaque_dilation(mask, radius)
        if fast is not None:
            return fast
    height = mask.shape[0]
    spans = {}
    for dy in range(-min(radius, height - 1), min(radius, height - 1) + 1):
        span = math.isqrt(radius * radius - dy * dy)
        spans.setdefault(span, []).append(dy)
    expanded = np.zeros_like(mask)
    for span, offsets in spans.items():
        row_max = horizontal_max(mask, span)
        for dy in offsets:
            source_y, target_y = max(0, -dy), max(0, dy)
            length = height - abs(dy)
            target = expanded[target_y:target_y + length]
            np.maximum(target, row_max[source_y:source_y + length], out=target)
    return expanded


@lru_cache(maxsize=32)
def gaussian_kernel(sigma):
    radius = int(np.ceil(3 * sigma))
    offsets = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-0.5 * (offsets / sigma) ** 2)
    kernel /= kernel.sum()
    return kernel


def blur_mask(mask, sigma):
    """Apply a separable Gaussian blur with transparent pixels outside the image."""
    if sigma <= 0:
        return mask.copy()
    kernel = gaussian_kernel(float(sigma))
    radius = len(kernel) // 2
    if radius > 3:
        blurred = mask
        for axis in (0, 1):
            length = blurred.shape[axis]
            fft_size = fft_length(length + len(kernel) - 1)
            frequencies = np.fft.rfft(blurred, n=fft_size, axis=axis)
            shape = [1, 1]
            shape[axis] = frequencies.shape[axis]
            frequencies *= np.fft.rfft(kernel, n=fft_size).reshape(shape)
            result = np.fft.irfft(frequencies, n=fft_size, axis=axis)
            window = [slice(None), slice(None)]
            window[axis] = slice(radius, radius + length)
            blurred = result[tuple(window)].astype(mask.dtype)
        blurred[blurred < 1e-7] = 0
        return blurred
    blurred = mask
    for axis in (0, 1):
        padding = [(0, 0), (0, 0)]
        padding[axis] = (radius, radius)
        padded = np.pad(blurred, padding)
        # Sum shifted copies: much faster than apply_along_axis for small kernels.
        result = np.zeros_like(blurred)
        length = blurred.shape[axis]
        for index, weight in enumerate(kernel):
            window = [slice(None), slice(None)]
            window[axis] = slice(index, index + length)
            result += weight * padded[tuple(window)]
        blurred = result
    return blurred


def post_process_pixels(pixels, settings, size, cache=None, key=None):
    """Adjust straight-alpha RGBA and composite the image over glow/shadow/outline."""
    scale = size / REFERENCE_RESOLUTION
    rgb = np.array(pixels[..., :3], dtype=np.float32, copy=True, order="C")
    alpha = np.clip(pixels[..., 3], 0.0, 1.0)
    saturation = settings["saturation"]
    if saturation != 1.0:
        gray = rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722
        rgb *= saturation
        rgb += ((1 - saturation) * gray)[..., None]
    if settings["contrast"] != 1.0:
        rgb -= 0.5
        rgb *= settings["contrast"]
        rgb += 0.5
    rgb *= settings["brightness"]
    np.clip(rgb, 0.0, 1.0, out=rgb)

    outline_width = int(round(settings["outlineSize"] * scale))
    outline_color = schema.hex_to_rgb(settings["outlineColor"])
    def cached(name, create):
        value = cache.get((key, name)) if cache is not None else None
        if value is None:
            value = create()
            if cache is not None:
                cache.put((key, name), value)
        return value

    silhouette = alpha
    if outline_width:
        silhouette = cached(("outline", outline_width), lambda: dilate_mask(alpha, outline_width))

    # Accumulate premultiplied layers from back to front, then return straight RGB.
    output_alpha = np.zeros_like(alpha)
    output_rgb = np.zeros_like(rgb)

    def composite(layer_rgb, layer_alpha):
        nonlocal output_rgb, output_alpha
        inverse = 1 - layer_alpha
        output_rgb *= inverse[..., None]
        output_rgb += layer_rgb * layer_alpha[..., None]
        output_alpha *= inverse
        output_alpha += layer_alpha

    if settings["glow"] and settings["glowOpacity"] > 0 and settings["glowSize"] > 0:
        glow_size = settings["glowSize"] * scale
        def make_glow():
            expanded = dilate_mask(silhouette, max(1, int(round(glow_size * 0.35))))
            return np.clip(blur_mask(expanded, glow_size * 0.5) * 1.6, 0.0, 1.0)
        glow = cached(("glow", outline_width, glow_size), make_glow)
        composite(np.asarray(schema.hex_to_rgb(settings["glowColor"]), dtype=np.float32), glow * settings["glowOpacity"])
    if settings["dropShadow"] and settings["shadowOpacity"] > 0:
        dx = int(round(settings["shadowOffsetX"] * scale))
        dy = int(round(settings["shadowOffsetY"] * scale))
        # Blender pixel rows run from bottom to top.
        sigma = settings["shadowBlur"] * scale
        blurred = cached(("shadow", outline_width, sigma), lambda: blur_mask(silhouette, sigma))
        shadow = shift_mask(blurred, dx, -dy)
        composite(np.asarray(schema.hex_to_rgb(settings["shadowColor"]), dtype=np.float32), shadow * settings["shadowOpacity"])
    if outline_width:
        composite(np.asarray(outline_color, dtype=np.float32), silhouette)
    composite(rgb, alpha)

    result = np.zeros_like(pixels)
    np.divide(output_rgb, output_alpha[..., None], out=result[..., :3],
              where=output_alpha[..., None] > 0)
    result[..., 3] = output_alpha
    return result


def cavity_angle_mask(normal_pixels, minimum_angle):
    """Select visible normal discontinuities, excluding background silhouettes."""
    normals = normal_pixels[..., :3] * 2.0 - 1.0
    lengths = np.linalg.norm(normals, axis=-1, keepdims=True)
    np.divide(normals, lengths, out=normals, where=lengths > 1e-6)
    valid = (normal_pixels[..., 3] > 0.999) & (lengths[..., 0] > 0.5)
    mask = np.zeros(valid.shape, dtype=np.float32)
    cosine = math.cos(math.radians(minimum_angle))
    # Workbench curvature samples a small neighborhood around each pixel.
    for dy, dx in ((0, 1), (1, 0), (0, 2), (2, 0)):
        height, width = valid.shape
        first = (slice(0, height - dy), slice(0, width - dx))
        second = (slice(dy, height), slice(dx, width))
        dot = np.sum(normals[first] * normals[second], axis=-1)
        selected = valid[first] & valid[second] & (dot <= cosine)
        np.maximum(mask[first], selected, out=mask[first])
        np.maximum(mask[second], selected, out=mask[second])
    # Cover the narrow highlight/shadow band on both sides of the crease.
    return dilate_mask(mask, 2)
