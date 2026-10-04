"""Roblox's own built-in material textures, downloaded at runtime.

Roblox publishes the ColorMap asset of every built-in material in its creator docs
(https://create.roblox.com/docs/parts/materials, "Asset and property reference"), for
both the current set and the pre-2022 set that places get with Use2022Materials off. Prism
downloads them like any other asset, so they are never bundled; when a download fails
it falls back to the approximations in materials.py.

This module stays dependency-free: the HTTP server imports it without numpy or Blender.
"""

CURRENT = {
    "Asphalt": "9930003046",
    "Basalt": "9920482056",
    "Brick": "9920482813",
    "Cardboard": "14108651729",
    "Carpet": "14108662587",
    "CeramicTiles": "17429425079",
    "ClayRoofTiles": "18147681935",
    "Cobblestone": "9919718991",
    "Concrete": "9920484153",
    "CorrodedMetal": "9920589327",
    "CrackedLava": "9920484943",
    "DiamondPlate": "10237720195",
    "Fabric": "9920517696",
    "Foil": "9466552117",
    "Glacier": "9920518732",
    "Granite": "9920550238",
    "Grass": "9920551868",
    "Ground": "9920554482",
    "Ice": "9920555943",
    "LeafyGrass": "9920557906",
    "Leather": "14108670073",
    "Limestone": "9920561437",
    "Marble": "9439430596",
    "Metal": "9920574687",
    "Mud": "9920578473",
    "Pavement": "9920579943",
    "Pebble": "9920581082",
    "Plaster": "14108671255",
    "Rock": "9920587470",
    "RoofShingles": "119722544879522",
    "Rubber": "14108673018",
    "Salt": "9920590225",
    "Sand": "9920591683",
    "Sandstone": "9920596120",
    "Slate": "9920599782",
    "Snow": "9920620284",
    "Wood": "9920625290",
    "WoodPlanks": "9920626778",
}

# Only the pre-2022 base set changes: on parts, terrain-type materials such as Asphalt
# keep their current textures even with Use2022Materials off. Glass is skipped, since
# Prism renders it as a plain transparent color, and the docs list a 4x4 placeholder
# for pre-2022 Foil and Ice, so both keep their current textures.
LEGACY = {
    "Brick": "7546648254",
    "Cobblestone": "7546651802",
    "Concrete": "7546653328",
    "CorrodedMetal": "7547183598",
    "DiamondPlate": "7546654401",
    "Fabric": "7547100606",
    "Granite": "7547164400",
    "Grass": "7547167347",
    "Marble": "7547174345",
    "Metal": "7547178395",
    "Pebble": "7547291174",
    "Sand": "7547294684",
    "Slate": "7547297050",
    "Wood": "7547190453",
    "WoodPlanks": "7547301709",
}

# Studs one texture tile spans on a part face. Roblox shows current materials at
# 1024 px per 8 studs, which Studio captures confirm.
CURRENT_STUDS_PER_TILE = 8.0
# Pre-2022 scales vary by material. Each was measured by template-matching the texture
# against top-down Studio captures; Wood and Metal are too flat to measure and use the
# common 10 studs.
LEGACY_STUDS_PER_TILE = {
    "Brick": 8.0,
    "Cobblestone": 15.0,
    "Concrete": 6.5,
    "CorrodedMetal": 10.0,
    "DiamondPlate": 5.0,
    "Fabric": 6.5,
    "Granite": 10.0,
    "Grass": 10.0,
    "Marble": 10.0,
    "Pebble": 10.0,
    "Sand": 10.0,
    "Slate": 10.0,
    "WoodPlanks": 8.0,
}
DEFAULT_LEGACY_STUDS_PER_TILE = 10.0


# On parts, Roblox shows these terrain-type materials much darker than their ColorMaps.
# Each gain is Studio's measured linear brightness for the material relative to the typical
# material, from top-down captures of 8 x 8 stud parts in the default part color.
GAIN = {
    "Asphalt": 0.33,
    "Pavement": 0.43,
    "Mud": 0.44,
    "LeafyGrass": 0.48,
    "Ground": 0.52,
    "Sandstone": 0.56,
    "Rock": 0.57,
    "Salt": 0.74,
    "Snow": 0.75,
}


def texture(name, legacy=False):
    """(asset id, studs per tile, brightness gain) of Roblox's texture for a built-in material, or None."""
    if legacy and name in LEGACY:
        return LEGACY[name], LEGACY_STUDS_PER_TILE.get(name, DEFAULT_LEGACY_STUDS_PER_TILE), 1.0
    if name in CURRENT:
        return CURRENT[name], CURRENT_STUDS_PER_TILE, GAIN.get(name, 1.0)
    return None
