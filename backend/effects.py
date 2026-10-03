"""Display-space image effects, independent of Blender."""

import math
from functools import lru_cache

import numpy as np

import schema

REFERENCE_RESOLUTION = 512
EFFECT_KEYS = schema.EFFECT_KEYS
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
HEAT_COLORS = ("#0A0050", "#2E3BFF", "#00D5FF", "#3DFF6E", "#FFF03C", "#FF7A1A", "#FF1A1A")
BAYER = np.array([
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
], dtype=np.float32)
# A drop between neighboring depths of this fraction of the model's depth draws a depth outline.
DEPTH_EDGE = 0.04


def required_passes(settings):
    """Extra Blender passes the enabled effects need besides the color render."""
    passes = set()
    if settings["xray"]:
        passes.add("normals")
    if settings["celShading"]:
        passes.add("flat")
    if settings["depthTint"] or settings["depthOutlineSize"] > 0 or (
        settings["heatmap"] and settings["heatmapSource"] == "depth"
    ):
        passes.add("depth")
    if text_visible(settings):
        passes.add("text")
    return passes


def text_visible(settings):
    """Text shows when any of its layers is visible, so outline-only text works."""
    if not settings["text"].strip():
        return False
    return (
        schema.hex_to_rgba(settings["textColor"])[3] > 0
        or (settings["textGradient"] and schema.hex_to_rgba(settings["textGradientColor"])[3] > 0)
        or (settings["textOutlineSize"] > 0 and schema.hex_to_rgba(settings["textOutlineColor"])[3] > 0)
        or (settings["textGlow"] and schema.hex_to_rgba(settings["textGlowColor"])[3] > 0)
        or (settings["textShadow"] and schema.hex_to_rgba(settings["textShadowColor"])[3] > 0)
    )


def text_fill(mask, settings):
    """Per-pixel straight RGBA for the text fill: solid, or a gradient across the text's bounds."""
    start = np.asarray(schema.hex_to_rgba(settings["textColor"]), dtype=np.float32)
    if not settings["textGradient"]:
        return np.broadcast_to(start, mask.shape + (4,))
    end = np.asarray(schema.hex_to_rgba(settings["textGradientColor"]), dtype=np.float32)
    height, width = mask.shape
    rows, columns = np.mgrid[0:height, 0:width].astype(np.float32)
    # Rows run bottom to top; the angle is measured clockwise on screen.
    angle = math.radians(settings["textGradientAngle"])
    projection = columns * math.cos(angle) + (height - 1 - rows) * math.sin(angle)
    covered = mask > 0.05
    low, high = (projection[covered].min(), projection[covered].max()) if np.any(covered) else (0.0, 1.0)
    t = np.clip((projection - low) / max(high - low, 1e-6), 0.0, 1.0)[..., None]
    return start + (end - start) * t


def text_layers(mask, settings, scale, cached, fill_mask=None):
    """Text shadow, glow, outline and fill as (rgb, alpha) layers, back to front."""
    layers = []
    signature = tuple(settings[name] for name in sorted(settings) if name.startswith("text"))
    if settings["textShadow"]:
        *color, opacity = schema.hex_to_rgba(settings["textShadowColor"])
        sigma = settings["textShadowBlur"] * scale
        blurred = cached(("textShadow", signature, sigma), lambda: blur_mask(mask, sigma))
        dx = int(round(settings["textShadowOffsetX"] * scale))
        dy = int(round(settings["textShadowOffsetY"] * scale))
        layers.append((color, shift_mask(blurred, dx, -dy) * opacity))
    if settings["textGlow"]:
        *color, opacity = schema.hex_to_rgba(settings["textGlowColor"])
        size = settings["textGlowSize"] * scale

        def make_glow():
            expanded = fractional_dilation(mask, max(0.5, size * 0.35))
            return np.clip(blur_mask(expanded, size * 0.5) * 1.6, 0.0, 1.0)

        layers.append((color, cached(("textGlow", signature, size), make_glow) * opacity))
    if settings["textOutlineSize"] > 0:
        *color, opacity = schema.hex_to_rgba(settings["textOutlineColor"])
        width = settings["textOutlineSize"] * scale
        outline = cached(("textOutline", signature, width), lambda: fractional_dilation(mask, width))
        layers.append((color, np.clip(outline, 0.0, 1.0) * opacity))
    fill = text_fill(mask, settings)
    layers.append((fill[..., :3], (mask if fill_mask is None else fill_mask) * fill[..., 3]))
    return layers


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


# ============================================================
# COLOR AND STYLIZE HELPERS
# All take straight-alpha RGB arrays (rows bottom first) and return new arrays.
# ============================================================

def luminance(rgb):
    return rgb @ LUMA


def gradient(t, colors):
    """Sample evenly spaced color stops at t in [0, 1]."""
    stops = np.asarray([schema.hex_to_rgb(color) for color in colors], dtype=np.float32)
    position = np.clip(t, 0.0, 1.0) * (len(stops) - 1)
    lower = np.minimum(position.astype(np.int32), len(stops) - 2)
    fraction = (position - lower)[..., None]
    return stops[lower] * (1 - fraction) + stops[lower + 1] * fraction


def smoothstep(edge0, edge1, value):
    span = np.asarray(edge1 - edge0, dtype=np.float32)
    span = np.where(np.abs(span) < 1e-6, 1e-6, span)
    t = np.clip((value - edge0) / span, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def cel_shade(rgb, levels, flat=None, coverage=None):
    """Quantize lighting into hard bands.

    With the unlit color pass, lighting is shaded / unlit brightness, so each
    surface keeps its own color and only the light steps. Without it, the
    brightness itself is banded.
    """
    if flat is None:
        value = rgb.max(axis=-1)
        banded = np.ceil(np.clip(value, 1e-4, 1.0) * levels) / levels
        scale = np.divide(banded, value, out=np.ones_like(value), where=value > 1e-4)
        return np.clip(rgb * scale[..., None], 0.0, 1.0)
    base = np.clip(flat[..., :3], 0.0, 1.0)
    base_light = luminance(base)
    lighting = np.divide(luminance(rgb), base_light, out=np.ones_like(base_light), where=base_light > 1e-3)
    solid = (coverage > 0.5) & (base_light > 1e-3) if coverage is not None else base_light > 1e-3
    # Stretch the model's own lighting range so differently lit faces fall into different bands.
    darkest, brightest = np.percentile(lighting[solid], (1, 99)) if np.any(solid) else (0.0, 1.0)
    span = max(float(brightest - darkest), 1e-3)
    steps = np.ceil(np.clip((lighting - darkest) / span, 1e-4, 1.0) * levels) / levels
    banded = darkest + steps * span
    result = np.where((base_light > 1e-3)[..., None], base * banded[..., None], rgb)
    return np.clip(result, 0.0, 1.0)


def halftone(rgb, cell, strength):
    """Rotated dot screen: darker pixels sit inside larger dots."""
    height, width = rgb.shape[:2]
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    u = (x + y) * (0.70710678 / cell)
    v = (x - y) * (0.70710678 / cell)
    distance = np.hypot(u - np.floor(u) - 0.5, v - np.floor(v) - 0.5) * 1.41421356
    radius = np.sqrt(np.clip(1 - luminance(rgb), 0.0, 1.0))
    edge = 1.0 / cell
    inside = smoothstep(radius + edge, radius - edge, distance)[..., None]
    paper = rgb + (1 - rgb) * (0.6 * strength)
    ink = rgb * (1 - 0.5 * strength)
    return paper + (ink - paper) * inside


def ordered_dither(rgb, levels, block):
    height, width = rgb.shape[:2]
    y = (np.arange(height) // block) % 8
    x = (np.arange(width) // block) % 8
    threshold = ((BAYER[y[:, None], x[None, :]] + 0.5) / 64)[..., None]
    steps = levels - 1
    return np.clip(np.floor(rgb * steps + threshold) / steps, 0.0, 1.0)


def depth_edges(depth, coverage):
    """Pixels next to a large depth jump between two covered neighbors."""
    edges = np.zeros(depth.shape, dtype=np.float32)
    solid = coverage > 0.5
    for dy, dx in ((0, 1), (1, 0)):
        height, width = depth.shape
        first = (slice(0, height - dy), slice(0, width - dx))
        second = (slice(dy, height), slice(dx, width))
        jump = (np.abs(depth[first] - depth[second]) > DEPTH_EDGE) & solid[first] & solid[second]
        np.maximum(edges[first], jump, out=edges[first])
        np.maximum(edges[second], jump, out=edges[second])
    return edges


def fractional_dilation(mask, radius):
    """Disk dilation that blends between integer radii for smooth thickness changes."""
    lower = int(math.floor(radius))
    blend = radius - lower
    result = dilate_mask(mask, lower)
    if blend > 1e-3:
        result = result + (dilate_mask(mask, lower + 1) - result) * blend
    return result


# ============================================================
# WHOLE-IMAGE HELPERS (premultiplied RGBA)
# ============================================================

def premultiply(rgb, alpha):
    return np.concatenate([rgb * alpha[..., None], alpha[..., None]], axis=-1)


def shift_channel(channel, dx):
    return shift_mask(channel, dx, 0)


def pixelate(image, block):
    height, width = image.shape[:2]
    pad_y, pad_x = -height % block, -width % block
    padded = np.pad(image, ((0, pad_y), (0, pad_x), (0, 0)))
    blocks = padded.reshape(padded.shape[0] // block, block, padded.shape[1] // block, block, 4).mean(axis=(1, 3))
    return np.repeat(np.repeat(blocks, block, axis=0), block, axis=1)[:height, :width]


def bilinear(image, sample_x, sample_y):
    """Sample an (h, w, c) image at float pixel coordinates; outside is transparent."""
    height, width = image.shape[:2]
    x0 = np.floor(sample_x).astype(np.int32)
    y0 = np.floor(sample_y).astype(np.int32)
    fx = (sample_x - x0)[..., None]
    fy = (sample_y - y0)[..., None]
    padded = np.pad(image, ((1, 1), (1, 1), (0, 0)))

    def at(yy, xx):
        return padded[np.clip(yy + 1, 0, height + 1), np.clip(xx + 1, 0, width + 1)]

    top = at(y0, x0) * (1 - fx) + at(y0, x0 + 1) * fx
    bottom = at(y0 + 1, x0) * (1 - fx) + at(y0 + 1, x0 + 1) * fx
    return top * (1 - fy) + bottom * fy


def crt(image, scanlines, curvature, scale):
    height, width = image.shape[:2]
    if curvature > 0:
        y, x = np.mgrid[0:height, 0:width].astype(np.float32)
        u = (x + 0.5) / width * 2 - 1
        v = (y + 0.5) / height * 2 - 1
        bulge = 1 + curvature * 0.3 * (u * u + v * v)
        image = bilinear(image, (u * bulge + 1) / 2 * width - 0.5, (v * bulge + 1) / 2 * height - 0.5)
    if scanlines > 0:
        period = max(2.0, 3.0 * scale)
        rows = np.arange(height, dtype=np.float32)
        lines = 1 - scanlines * 0.6 * (0.5 - 0.5 * np.cos(2 * np.pi * rows / period))
        image = image.copy()
        image[..., :3] *= lines[:, None, None]
        # Phosphor triads: each column favors one primary.
        columns = (np.arange(width) // max(1, int(round(scale)))) % 3
        mask = np.full((width, 3), 1 - 0.35 * scanlines, dtype=np.float32)
        mask[np.arange(width), columns] = 1
        image[..., :3] *= mask[None]
    return image


def bloom(image, threshold, intensity, radius):
    alpha = image[..., 3]
    straight = np.divide(image[..., :3], alpha[..., None], out=np.zeros_like(image[..., :3]),
                         where=alpha[..., None] > 0)
    weight = np.clip((luminance(straight) - threshold) / max(1 - threshold, 1e-3), 0.0, 1.0)
    bright = image[..., :3] * weight[..., None]
    glow = np.stack([blur_mask(bright[..., channel], radius) for channel in range(3)], axis=-1) * intensity
    result = image.copy()
    result[..., :3] += glow
    result[..., 3] = np.clip(np.maximum(alpha, luminance(glow)), 0.0, 1.0)
    result[..., :3] = np.minimum(result[..., :3], result[..., 3:4])
    return result


def vignette_alpha(height, width, strength):
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    distance = np.hypot((x + 0.5) / width - 0.5, (y + 0.5) / height - 0.5) / 0.70710678
    return smoothstep(1 - strength, 1.0, distance)


def over(image, rgb, alpha):
    """Composite a straight-color layer over a premultiplied image."""
    inverse = 1 - alpha[..., None]
    result = image * inverse
    result[..., :3] += np.asarray(rgb, dtype=np.float32) * alpha[..., None]
    result[..., 3] += alpha
    return result


def post_adjust(rgb, settings):
    """Saturation, contrast and brightness on a copy of straight RGB."""
    rgb = np.array(rgb, dtype=np.float32, copy=True, order="C")
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
    return rgb


def post_process_pixels(pixels, settings, size, cache=None, key=None, passes=None):
    """Apply image effects to straight-alpha RGBA (rows bottom first).

    Layers, back to front: glow, drop shadow, outline, the styled model, then
    whole-image effects, the vignette and finally the text.
    passes holds the extra Blender passes from required_passes().
    """
    passes = passes or {}
    scale = size / REFERENCE_RESOLUTION
    rgb = post_adjust(pixels[..., :3], settings)
    alpha = np.clip(pixels[..., 3], 0.0, 1.0)

    def cached(name, create):
        value = cache.get((key, name)) if cache is not None else None
        if value is None:
            value = create()
            if cache is not None:
                cache.put((key, name), value)
        return value

    depth = passes.get("depth")
    depth_value = depth[..., 0] if depth is not None else None

    # ---- model color and stylize ----------------------------------------
    if settings["celShading"]:
        flat = passes.get("flat")
        if flat is not None:
            # Match the color adjustments applied to the shaded render above.
            flat = post_adjust(flat[..., :3], settings)
        rgb = cel_shade(rgb, int(settings["celLevels"]), flat, alpha)
    if settings["heatmap"]:
        if settings["heatmapSource"] == "depth" and depth_value is not None:
            heat = 1 - depth_value
        else:
            heat = luminance(rgb)
        rgb = gradient(heat, HEAT_COLORS)
    if settings["duotone"]:
        rgb = gradient(luminance(rgb), (settings["duotoneShadow"], settings["duotoneHighlight"]))
    if settings["tritone"]:
        rgb = gradient(luminance(rgb), (settings["tritoneShadow"], settings["tritoneMidtone"], settings["tritoneHighlight"]))
    if settings["depthTint"] and depth_value is not None:
        amount = (np.clip(depth_value, 0.0, 1.0) * settings["depthTintStrength"])[..., None]
        rgb = rgb + (np.asarray(schema.hex_to_rgb(settings["depthTintColor"]), dtype=np.float32) - rgb) * amount
    normals = passes.get("normals")
    if settings["xray"] and normals is not None:
        facing = np.abs(normals[..., 2] * 2 - 1)
        rim = np.clip(1 - facing, 0.0, 1.0) ** settings["xrayFalloff"]
        color = np.asarray(schema.hex_to_rgb(settings["xrayColor"]), dtype=np.float32)
        rgb = color * (0.35 + 0.65 * rim)[..., None]
        alpha = alpha * np.clip(0.2 + 0.8 * rim, 0.0, 1.0)
    # Masks derived from alpha must not be shared between X-ray and normal renders.
    alpha_variant = ("xray", settings["xrayFalloff"]) if settings["xray"] and normals is not None else ()
    if settings["halftone"] and settings["halftoneStrength"] > 0:
        rgb = halftone(rgb, max(2.0, settings["halftoneSize"] * scale), settings["halftoneStrength"])
    if settings["innerShadow"] and settings["innerShadowOpacity"] > 0:
        sigma = settings["innerShadowBlur"] * scale
        blurred = cached(("inner", sigma, *alpha_variant), lambda: blur_mask(alpha, sigma))
        dx = int(round(settings["innerShadowOffsetX"] * scale))
        dy = int(round(settings["innerShadowOffsetY"] * scale))
        # Shift the blurred silhouette away from the light; uncovered edges are in shadow.
        shade = (1 - shift_mask(blurred, dx, -dy)) * settings["innerShadowOpacity"]
        color = np.asarray(schema.hex_to_rgb(settings["innerShadowColor"]), dtype=np.float32)
        rgb = rgb + (color - rgb) * np.clip(shade, 0.0, 1.0)[..., None]
    if settings["depthOutlineSize"] > 0 and depth_value is not None:
        thickness = settings["depthOutlineSize"] * scale / 2
        lines = cached(("depthOutline", thickness, *alpha_variant),
                       lambda: blur_mask(fractional_dilation(depth_edges(depth_value, alpha), thickness), 0.6 * max(scale, 0.5)))
        color = np.asarray(schema.hex_to_rgb(settings["depthOutlineColor"]), dtype=np.float32)
        rgb = rgb + (color - rgb) * np.clip(lines, 0.0, 1.0)[..., None]
    if settings["colorOverlay"]:
        *color, opacity = schema.hex_to_rgba(settings["colorOverlayColor"])
        rgb = rgb + (np.asarray(color, dtype=np.float32) - rgb) * opacity
    rgb = np.clip(rgb, 0.0, 1.0)

    # ---- silhouette layers ----------------------------------------------
    outline_width = int(round(settings["outlineSize"] * scale))
    outline_color = schema.hex_to_rgb(settings["outlineColor"])

    silhouette = alpha
    if outline_width:
        silhouette = cached(("outline", outline_width, *alpha_variant), lambda: dilate_mask(alpha, outline_width))

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
        glow = cached(("glow", outline_width, glow_size, *alpha_variant), make_glow)
        composite(np.asarray(schema.hex_to_rgb(settings["glowColor"]), dtype=np.float32), glow * settings["glowOpacity"])
    if settings["dropShadow"] and settings["shadowOpacity"] > 0:
        dx = int(round(settings["shadowOffsetX"] * scale))
        dy = int(round(settings["shadowOffsetY"] * scale))
        # Blender pixel rows run from bottom to top.
        sigma = settings["shadowBlur"] * scale
        blurred = cached(("shadow", outline_width, sigma, *alpha_variant), lambda: blur_mask(silhouette, sigma))
        shadow = shift_mask(blurred, dx, -dy)
        composite(np.asarray(schema.hex_to_rgb(settings["shadowColor"]), dtype=np.float32), shadow * settings["shadowOpacity"])
    if outline_width:
        composite(np.asarray(outline_color, dtype=np.float32), silhouette)
    composite(rgb, alpha)

    # ---- whole-image effects (premultiplied) -----------------------------
    image = np.concatenate([output_rgb, output_alpha[..., None]], axis=-1)
    if settings["bloom"] and settings["bloomIntensity"] > 0:
        image = bloom(image, settings["bloomThreshold"], settings["bloomIntensity"], settings["bloomRadius"] * scale)
    if settings["pixelate"]:
        block = max(2, int(round(settings["pixelSize"] * scale)))
        image = pixelate(image, block)
    if settings["dither"]:
        image_alpha = image[..., 3]
        straight = np.divide(image[..., :3], image_alpha[..., None], out=np.zeros_like(image[..., :3]),
                             where=image_alpha[..., None] > 0)
        block = max(1, int(round(settings["ditherScale"] * scale)))
        image = premultiply(ordered_dither(straight, int(settings["ditherLevels"]), block), image_alpha)
    if settings["chromaticAberration"]:
        offset = max(1, int(round(settings["chromaticAmount"] * scale)))
        red = shift_channel(image[..., 0], offset)
        blue = shift_channel(image[..., 2], -offset)
        coverage = np.maximum.reduce([shift_channel(image[..., 3], offset), image[..., 3],
                                      shift_channel(image[..., 3], -offset)])
        image = np.stack([red, image[..., 1], blue, coverage], axis=-1)
    if settings["vignette"] and settings["vignetteOpacity"] > 0 and settings["vignetteStrength"] > 0:
        height, width = alpha.shape
        amount = vignette_alpha(height, width, settings["vignetteStrength"]) * settings["vignetteOpacity"]
        image = over(image, schema.hex_to_rgb(settings["vignetteColor"]), amount)
    if settings["crt"]:
        image = crt(image, settings["crtScanlines"], settings["crtCurvature"], scale)
    text = passes.get("text")
    if text is not None and text_visible(settings):
        dx, dy = int(round(settings["textOffsetX"] * scale)), -int(round(settings["textOffsetY"] * scale))
        if text.ndim == 3:
            colored = np.stack([shift_mask(text[..., channel], dx, dy) for channel in range(4)], axis=2)
            fill_mask = shift_mask(text[..., 4], dx, dy)
            coverage = np.maximum(fill_mask, colored[..., 3])
            for color, amount in text_layers(coverage, settings, scale, cached, fill_mask=fill_mask):
                image = over(image, color, amount)
            opacity = schema.hex_to_rgba(settings["textColor"])[3]
            image = over(image, colored[..., :3], colored[..., 3] * opacity)
        else:
            text = shift_mask(text, dx, dy)
            for color, amount in text_layers(np.clip(text, 0.0, 1.0), settings, scale, cached):
                image = over(image, color, amount)

    image = np.clip(image, 0.0, 1.0)
    result = np.zeros_like(pixels)
    np.divide(image[..., :3], image[..., 3:4], out=result[..., :3], where=image[..., 3:4] > 0)
    result[..., 3] = image[..., 3]
    return np.clip(result, 0.0, 1.0)


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
