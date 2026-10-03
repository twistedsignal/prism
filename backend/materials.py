"""Tileable detail textures for Roblox's built-in materials.

Roblox streams its material textures at runtime instead of shipping them with
Studio, so Prism generates a seamless grayscale detail map per material. The
renderer multiplies it by the part color, as Roblox tints its materials.
Custom MaterialVariants use their real ColorMap instead.
"""

import base64
from functools import lru_cache

import numpy as np

SIZE = 256
DEFAULT_STUDS_PER_TILE = 4.0

# Materials that render as a plain color.
UNTEXTURED = frozenset({"Plastic", "SmoothPlastic", "Neon", "Glass", "ForceField"})


# ============================================================
# NOISE (every function tiles seamlessly over SIZE x SIZE)
# ============================================================

def grid(seed):
    return np.random.default_rng(seed)


def value_noise(seed, cells_x, cells_y=None):
    """Smooth periodic value noise with the given number of cells per tile."""
    cells_y = cells_y or cells_x
    values = grid(seed).random((cells_y, cells_x)).astype(np.float32)
    ys = np.arange(SIZE, dtype=np.float32) * cells_y / SIZE
    xs = np.arange(SIZE, dtype=np.float32) * cells_x / SIZE
    y0, x0 = ys.astype(int), xs.astype(int)
    ty, tx = ys - y0, xs - x0
    ty, tx = ty * ty * (3 - 2 * ty), tx * tx * (3 - 2 * tx)
    y1, x1 = (y0 + 1) % cells_y, (x0 + 1) % cells_x
    top = values[y0][:, x0] * (1 - tx) + values[y0][:, x1] * tx
    bottom = values[y1][:, x0] * (1 - tx) + values[y1][:, x1] * tx
    return top * (1 - ty)[:, None] + bottom * ty[:, None]


def fbm(seed, cells_x, cells_y=None, octaves=4):
    """Fractal noise in [0, 1]."""
    cells_y = cells_y or cells_x
    total = np.zeros((SIZE, SIZE), dtype=np.float32)
    weight = 0.0
    amplitude = 1.0
    for octave in range(octaves):
        scale = 2 ** octave
        total += value_noise(seed + octave, cells_x * scale, cells_y * scale) * amplitude
        weight += amplitude
        amplitude *= 0.5
    return total / weight


def voronoi(seed, count):
    """Periodic Voronoi cells: (distance to the nearest point, distance to the cell's edge, cell id)."""
    # One jittered point per grid cell spaces stones evenly; pure random points
    # cluster and leave thin wedge-shaped cells.
    side = max(2, int(round(np.sqrt(count))))
    jitter = grid(seed).random((side, side, 2)).astype(np.float32) * 0.8 + 0.1
    rows, columns = np.mgrid[0:side, 0:side].astype(np.float32)
    points = (np.stack([columns, rows], axis=-1) + jitter).reshape(-1, 2) / side
    count = len(points)
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32) / SIZE

    def wrapped(px, py):
        dx = np.abs(xs - px)
        dy = np.abs(ys - py)
        return np.minimum(dx, 1 - dx), np.minimum(dy, 1 - dy)

    nearest = np.full((SIZE, SIZE), np.inf, dtype=np.float32)
    cell = np.zeros((SIZE, SIZE), dtype=np.int32)
    for index, (px, py) in enumerate(points):
        distance = np.hypot(*wrapped(px, py))
        cell = np.where(distance < nearest, index, cell)
        nearest = np.minimum(nearest, distance)
    # The edge is the closest bisector between this pixel's point and any other point.
    # Use the periodic image of each point that is nearest to the pixel's own point.
    edge = np.full((SIZE, SIZE), np.inf, dtype=np.float32)
    own = points[cell]
    for index, (px, py) in enumerate(points):
        offset = np.stack([px - own[..., 0], py - own[..., 1]], axis=-1)
        offset -= np.round(offset)
        length = np.linalg.norm(offset, axis=-1)
        relative = np.stack([xs - own[..., 0], ys - own[..., 1]], axis=-1)
        relative -= np.round(relative)
        # Signed distance from the pixel to the perpendicular bisector of own -> other.
        along = np.sum(relative * offset, axis=-1) / np.maximum(length, 1e-6)
        distance = length / 2 - along
        distance = np.where(cell == index, np.inf, distance)
        edge = np.minimum(edge, distance)
    return nearest, np.maximum(edge, 0.0), cell


def per_cell(seed, cell, count):
    return grid(seed).random(max(count, int(cell.max()) + 1)).astype(np.float32)[cell]


def coordinates():
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    return xs / SIZE, ys / SIZE


def seams(position, count, width):
    """1 on thin lines between count equal bands, else 0."""
    band = (position * count) % 1.0
    edge = width * count
    return ((band < edge) | (band > 1 - edge)).astype(np.float32)


# ============================================================
# PATTERNS (values around 0.6-1.0, multiplied by the part color)
# ============================================================

def wood(seed=1):
    x, y = coordinates()
    warp = fbm(seed, 2, 6) * 2.5
    rings = 0.5 + 0.5 * np.sin(2 * np.pi * (y * 6 + warp))
    streaks = fbm(seed + 10, 2, 48, octaves=3)
    return 0.72 + 0.14 * rings + 0.12 * streaks


def wood_planks(seed=2):
    x, y = coordinates()
    rows = 4
    row = np.floor(y * rows).astype(int)
    offsets = grid(seed).random(rows).astype(np.float32)
    shade = grid(seed + 1).random((rows, 2)).astype(np.float32)
    shifted = (x + offsets[row]) % 1.0
    plank = (shifted >= 0.5).astype(int)
    tone = 0.85 + 0.1 * (shade[row, plank] - 0.5)
    grain = 0.88 + 0.12 * wood(seed + 5)
    gaps = np.maximum(seams(y, rows, 0.006), (np.abs(shifted - 0.5) < 0.004) | (shifted < 0.004))
    return tone * grain * (1 - 0.45 * gaps)


def brick(seed=3):
    x, y = coordinates()
    rows, columns = 8, 4
    row = np.floor(y * rows).astype(int)
    shifted = (x + (row % 2) * 0.5 / columns) % 1.0
    column = np.floor(shifted * columns).astype(int)
    tone = grid(seed).random((rows, columns)).astype(np.float32)[row, column]
    mortar = np.maximum(seams(y, rows, 0.008), seams(shifted, columns, 0.006))
    face = 0.78 + 0.1 * (tone - 0.5) + 0.1 * fbm(seed + 4, 16)
    return face * (1 - mortar) + 0.98 * mortar


def stones(seed, count, gap, rounded=False):
    nearest, edge, cell = voronoi(seed, count)
    tone = 0.8 + 0.16 * (per_cell(seed + 1, cell, count) - 0.5)
    if rounded:
        tone = tone * (1 - 0.25 * np.clip(nearest * np.sqrt(count) * 1.4, 0, 1) ** 2)
    surface = tone + 0.06 * (fbm(seed + 2, 24) - 0.5)
    return np.where(edge < gap, 0.45 + 0.3 * edge / gap, surface)


def grainy(seed, cells, contrast, base=0.82, octaves=4):
    return base + contrast * (fbm(seed, cells, octaves=octaves) - 0.5)


def speckled(seed, density, contrast):
    noise = value_noise(seed, 128)
    spots = np.where(noise > 1 - density, -contrast, 0.0) + np.where(noise < density * 0.6, contrast * 0.6, 0.0)
    return 0.84 + spots + 0.06 * (fbm(seed + 1, 8) - 0.5)


def slate(seed=6):
    layers = fbm(seed, 2, 12)
    return 0.7 + 0.25 * layers + 0.06 * (fbm(seed + 3, 32) - 0.5)


def marble(seed=7):
    x, y = coordinates()
    turbulence = fbm(seed, 4, octaves=5) * 4
    # Whole-number frequencies keep the veins seamless across tiles.
    veins = np.abs(np.sin(2 * np.pi * (x * 2 + y + turbulence * 0.35)))
    return 0.95 - 0.22 * (1 - veins) ** 6 - 0.05 * fbm(seed + 2, 8)


def brushed_metal(seed=8):
    return 0.86 + 0.1 * (fbm(seed, 2, 96, octaves=3) - 0.5) + 0.05 * (fbm(seed + 1, 4) - 0.5)


def diamond_plate(seed=9):
    x, y = coordinates()
    count = 8
    u, v = (x * count) % 1.0, (y * count) % 1.0
    # Two families of raised diamonds, alternating direction.
    first = np.abs(u - 0.25) * 0.6 + np.abs(v - 0.25) * 1.6 < 0.18
    second = np.abs(u - 0.75) * 1.6 + np.abs(v - 0.75) * 0.6 < 0.18
    raised = (first | second).astype(np.float32)
    return 0.78 + 0.18 * raised + 0.05 * (fbm(seed, 4) - 0.5)


def corroded(seed=10):
    rust = fbm(seed, 6, octaves=5)
    pits = (value_noise(seed + 2, 96) > 0.86).astype(np.float32)
    return 0.62 + 0.3 * rust - 0.12 * pits


def foil(seed=11):
    _, _, cell = voronoi(seed, 60)
    return 0.8 + 0.2 * per_cell(seed + 1, cell, 60)


def weave(seed=12, threads=16, contrast=0.22):
    x, y = coordinates()
    warp = 0.5 + 0.5 * np.sin(2 * np.pi * x * threads)
    weft = 0.5 + 0.5 * np.sin(2 * np.pi * y * threads)
    over = ((np.floor(x * threads) + np.floor(y * threads)) % 2).astype(np.float32)
    pattern = over * warp + (1 - over) * weft
    return 0.82 + contrast * (pattern - 0.5) + 0.04 * (fbm(seed, 8) - 0.5)


def grass(seed=13, base=0.78):
    blades = fbm(seed, 24, 6, octaves=3)
    clumps = fbm(seed + 1, 4)
    return base + 0.2 * (blades - 0.5) + 0.12 * (clumps - 0.5)


def cracked(seed, count, crack, glow=False):
    _, edge, cell = voronoi(seed, count)
    plates = 0.7 + 0.15 * (per_cell(seed + 1, cell, count) - 0.5) + 0.05 * (fbm(seed + 2, 16) - 0.5)
    line = np.clip(1 - edge / crack, 0, 1)
    return plates + line * (0.3 if glow else -0.25)


def tiles(seed, count, gap, base=0.88):
    x, y = coordinates()
    lines = np.maximum(seams(x, count, gap), seams(y, count, gap))
    tone = grid(seed).random((count, count)).astype(np.float32)
    row = np.minimum((y * count).astype(int), count - 1)
    column = np.minimum((x * count).astype(int), count - 1)
    face = base + 0.06 * (tone[row, column] - 0.5) + 0.04 * (fbm(seed + 1, 16) - 0.5)
    return face * (1 - lines) + 0.6 * lines


def roof_tiles(seed=15, rows=6, columns=6, scallop=True):
    x, y = coordinates()
    row = np.floor(y * rows).astype(int)
    shifted = (x + (row % 2) * 0.5 / columns) % 1.0
    u = (shifted * columns) % 1.0
    v = (y * rows) % 1.0
    if scallop:
        shape = 1 - np.clip(((u - 0.5) * 2) ** 2 + (v - 1.0) ** 2 * 0.6, 0, 1)
        lower = v > 0.85 - 0.25 * np.abs(u - 0.5)
    else:
        shape = v
        lower = v > 0.94
    tone = grid(seed).random((rows, columns)).astype(np.float32)[row, np.floor(shifted * columns).astype(int)]
    face = 0.7 + 0.2 * shape + 0.08 * (tone - 0.5)
    return np.where(lower | (np.abs(u - 0.5) > 0.48), face * 0.7, face)


def corrugated(seed=16):
    x, y = coordinates()
    return 0.84 + 0.08 * np.sin(2 * np.pi * y * 24) + 0.05 * (fbm(seed, 6) - 0.5)


GENERATORS = {
    "Wood": wood,
    "WoodPlanks": wood_planks,
    "Brick": brick,
    "Cobblestone": lambda: stones(4, 28, 0.012),
    "Pebble": lambda: stones(5, 60, 0.008, rounded=True),
    "Rock": lambda: 0.6 + 0.3 * fbm(17, 4, octaves=6),
    "Basalt": lambda: cracked(18, 40, 0.008),
    "CrackedLava": lambda: cracked(19, 30, 0.012, glow=True),
    "Concrete": lambda: grainy(20, 16, 0.12),
    "Plaster": lambda: grainy(21, 8, 0.08, base=0.88),
    "Limestone": lambda: grainy(22, 6, 0.16, base=0.86),
    "Sandstone": lambda: 0.8 + 0.1 * np.sin(2 * np.pi * (coordinates()[1] * 8 + fbm(23, 3) * 1.5)) * 0.5
    + 0.08 * (fbm(24, 24) - 0.5),
    "Slate": slate,
    "Granite": lambda: speckled(25, 0.12, 0.18),
    "Marble": marble,
    "Pavement": lambda: tiles(26, 4, 0.006, base=0.84),
    "Asphalt": lambda: speckled(27, 0.2, 0.12) - 0.06,
    "Salt": lambda: speckled(28, 0.1, 0.1) + 0.06,
    "Ground": lambda: grainy(29, 10, 0.22, base=0.76),
    "Mud": lambda: grainy(30, 6, 0.2, base=0.72),
    "Sand": lambda: grainy(31, 64, 0.12, base=0.86, octaves=2),
    "Snow": lambda: grainy(32, 12, 0.08, base=0.94),
    "Ice": lambda: cracked(33, 12, 0.004) + 0.12,
    "Glacier": lambda: cracked(34, 18, 0.006) + 0.1,
    "Grass": grass,
    "LeafyGrass": lambda: grass(35, base=0.74) - 0.08 * stones(36, 40, 0.01),
    "Metal": brushed_metal,
    "DiamondPlate": diamond_plate,
    "CorrodedMetal": corroded,
    "Foil": foil,
    "Fabric": weave,
    "Carpet": lambda: grainy(37, 96, 0.14, base=0.82, octaves=2),
    "Leather": lambda: stones(38, 140, 0.004) * 0.15 + 0.72,
    "Rubber": lambda: grainy(39, 48, 0.06, base=0.8, octaves=2),
    "Cardboard": corrugated,
    "CeramicTiles": lambda: tiles(40, 4, 0.01, base=0.92),
    "ClayRoofTiles": roof_tiles,
    "RoofShingles": lambda: roof_tiles(41, rows=8, columns=5, scallop=False),
}

STUDS_PER_TILE = {
    "WoodPlanks": 8.0, "Brick": 8.0, "Cobblestone": 8.0, "Pavement": 8.0, "CeramicTiles": 8.0,
    "ClayRoofTiles": 8.0, "RoofShingles": 8.0, "DiamondPlate": 4.0, "Fabric": 2.0, "Carpet": 4.0,
}


def has_texture(name):
    return name in GENERATORS


def studs_per_tile(name):
    return STUDS_PER_TILE.get(name, DEFAULT_STUDS_PER_TILE)


@lru_cache(maxsize=48)
def texture(name):
    """{"width", "height", "pixels"} RGBA8 rows top-down, like plugin textures."""
    values = np.clip(GENERATORS[name](), 0.0, 1.0)
    gray = (values * 255 + 0.5).astype(np.uint8)
    rgba = np.empty((SIZE, SIZE, 4), dtype=np.uint8)
    rgba[..., :3] = gray[..., None]
    rgba[..., 3] = 255
    return {"width": SIZE, "height": SIZE, "pixels": base64.b64encode(rgba.tobytes()).decode("ascii")}


def neon_color(rgb):
    """Neon glows in Roblox; lift the color so Workbench shading doesn't dull it."""
    return tuple(channel + (1 - channel) * 0.35 for channel in rgb)
