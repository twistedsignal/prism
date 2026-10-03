"""Render settings schema: the single source of truth for the plugin UI and renderer."""

import math
import re

# Key light direction defaults reproduce the original fixed camera rig:
# camera direction (1.4, -1.7, 1.15) and key light (-0.45, 0.55, 0.80).
# Sections hold settings and nested {"type": "group"} entries. "requires" hides a
# setting or group in the plugin unless another setting is on (bools), non-zero
# (numbers) or non-empty (text); "!key" inverts it. Hidden settings never affect
# the render, because they only matter when their requirement holds.
SECTIONS = [
    {
        "id": "stance",
        "label": "Model stance",
        "settings": [
            {"key": "pitch", "label": "Pitch (X)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the X axis, in degrees."},
            {"key": "yaw", "label": "Yaw (Y)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the vertical (Y) axis, in degrees."},
            {"key": "roll", "label": "Roll (Z)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the Z axis, in degrees."},
        ],
    },
    {
        "id": "camera",
        "label": "Camera",
        "settings": [
            {"key": "cameraRotation", "label": "Rotation", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": 39.5,
             "description": "Orbits the camera around the model, in degrees. 0 faces the model's front."},
            {"key": "cameraElevation", "label": "Elevation", "type": "number", "min": -89, "max": 89, "step": 0.5, "default": 27.5,
             "description": "Camera height angle above the model, in degrees."},
            {"key": "cameraRoll", "label": "Roll", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": 0,
             "description": "Tilts the camera around its view axis, in degrees."},
            {"key": "zoom", "label": "Zoom", "type": "number", "min": 0.1, "max": 5, "step": 0.01, "default": 1,
             "description": "Larger values zoom in on the model."},
            {"key": "orthographic", "label": "Orthographic", "type": "bool", "default": True,
             "description": "Use an orthographic camera instead of perspective."},
            {"key": "fov", "label": "FOV", "type": "number", "min": 5, "max": 120, "step": 0.5, "default": 30, "auto": "fovAuto", "requires": "!orthographic",
             "description": "Perspective field of view in degrees. Auto uses a long lens that matches the orthographic framing."},
            {"key": "fovAuto", "label": "FOV auto", "type": "bool", "default": True, "hidden": True},
        ],
    },
    {
        "id": "lighting",
        "label": "Lighting",
        "settings": [
            {"key": "exposure", "label": "Global exposure", "type": "number", "min": -3, "max": 3, "step": 0.01, "default": 0,
             "description": "Scene exposure in stops."},
            {
                "type": "group",
                "id": "sun",
                "label": "Sun",
                "settings": [
                    {"key": "sunColor", "label": "Sun color", "type": "color", "default": "#FFFFFF",
                     "description": "Color of the main light."},
                    {"key": "sunIntensity", "label": "Sun intensity", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
                     "description": "Strength of the main light."},
                    {"key": "sunRotation", "label": "Sun rotation", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": -29.5,
                     "description": "Main light direction around the view, relative to the camera, in degrees."},
                    {"key": "sunElevation", "label": "Sun elevation", "type": "number", "min": -89, "max": 89, "step": 0.5, "default": 31,
                     "description": "Main light height relative to the camera, in degrees."},
                ],
            },
            {
                "type": "group",
                "id": "castShadows",
                "label": "Cast shadows",
                "settings": [
                    {"key": "castShadows", "label": "Cast shadows", "type": "bool", "default": True,
                     "description": "Let the sun cast shadows onto the model."},
                    {"key": "shadowIntensity", "label": "Shadow intensity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.32, "requires": "castShadows",
                     "description": "How dark cast shadows are."},
                ],
            },
            {
                "type": "group",
                "id": "secondary",
                "label": "Fill and rim",
                "settings": [
                    {"key": "secondaryColor", "label": "Secondary color", "type": "color", "default": "#FFFFFF",
                     "description": "Color of the fill and rim lights."},
                    {"key": "secondaryIntensity", "label": "Secondary intensity", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
                     "description": "Strength of the fill and rim lights."},
                ],
            },
            {
                "type": "group",
                "id": "ambient",
                "label": "Ambient",
                "settings": [
                    {"key": "ambientColor", "label": "Ambient color", "type": "color", "default": "#FFFFFF",
                     "description": "Color of the light that reaches every surface."},
                    {"key": "ambientIntensity", "label": "Ambient intensity", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.5145,
                     "description": "Strength of the ambient light."},
                ],
            },
        ],
    },
    {
        "id": "material",
        "label": "Material",
        "settings": [
            {"key": "transparency", "label": "Enable transparency", "type": "bool", "default": True,
             "description": "Honor part transparency and texture alpha."},
            {"key": "specular", "label": "Specular", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0,
             "description": "Strength of specular highlights. Roughness only matters above zero."},
            {"key": "roughness", "label": "Roughness", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5, "requires": "specular",
             "description": "Surface roughness used for specular highlights."},
        ],
    },
    {
        "id": "adjustments",
        "label": "Adjustments",
        "effects": True,
        "settings": [
            {"key": "saturation", "label": "Saturation", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "0 is grayscale, 1 leaves colors unchanged."},
            {"key": "contrast", "label": "Contrast", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "1 leaves contrast unchanged."},
            {"key": "brightness", "label": "Brightness", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "1 leaves brightness unchanged."},
        ],
    },
    {
        "id": "silhouette",
        "label": "Silhouette",
        "effects": True,
        "settings": [
            {
                "type": "group",
                "id": "outline",
                "label": "Outline",
                "settings": [
                    {"key": "outlineSize", "label": "Outline size", "type": "number", "min": 0, "max": 40, "step": 1, "default": 10,
                     "description": "Outline width in pixels at 512px. 0 disables the outline."},
                    {"key": "outlineColor", "label": "Outline color", "type": "color", "default": "#000000", "requires": "outlineSize",
                     "description": "Color of the silhouette outline."},
                ],
            },
            {
                "type": "group",
                "id": "dropShadow",
                "label": "Drop shadow",
                "settings": [
                    {"key": "dropShadow", "label": "Enable drop shadow", "type": "bool", "default": True,
                     "description": "Draw a soft shadow behind the silhouette."},
                    {"key": "shadowColor", "label": "Shadow color", "type": "color", "default": "#000000", "requires": "dropShadow",
                     "description": "Color of the drop shadow."},
                    {"key": "shadowOpacity", "label": "Shadow opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.35, "requires": "dropShadow",
                     "description": "Opacity of the drop shadow."},
                    {"key": "shadowBlur", "label": "Shadow blur", "type": "number", "min": 0, "max": 60, "step": 0.5, "default": 25, "requires": "dropShadow",
                     "description": "Blur radius of the drop shadow in pixels at 512px."},
                    {"key": "shadowOffsetX", "label": "Shadow X offset", "type": "number", "min": -64, "max": 64, "step": 1, "default": 12, "requires": "dropShadow",
                     "description": "Positive values move the shadow right."},
                    {"key": "shadowOffsetY", "label": "Shadow Y offset", "type": "number", "min": -64, "max": 64, "step": 1, "default": 12, "requires": "dropShadow",
                     "description": "Positive values move the shadow down."},
                ],
            },
            {
                "type": "group",
                "id": "glow",
                "label": "Glow",
                "settings": [
                    {"key": "glow", "label": "Enable glow", "type": "bool", "default": False,
                     "description": "Draw a soft colored glow behind the silhouette."},
                    {"key": "glowColor", "label": "Glow color", "type": "color", "default": "#FFD966", "requires": "glow",
                     "description": "Color of the glow."},
                    {"key": "glowOpacity", "label": "Glow opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.8, "requires": "glow",
                     "description": "Opacity of the glow."},
                    {"key": "glowSize", "label": "Glow size", "type": "number", "min": 0, "max": 64, "step": 1, "default": 16, "requires": "glow",
                     "description": "Glow spread in pixels at 512px."},
                ],
            },
            {
                "type": "group",
                "id": "innerShadow",
                "label": "Inner shadow",
                "settings": [
                    {"key": "innerShadow", "label": "Enable inner shadow", "type": "bool", "default": False,
                     "description": "Shade the inside edges of the silhouette."},
                    {"key": "innerShadowColor", "label": "Inner shadow color", "type": "color", "default": "#000000", "requires": "innerShadow",
                     "description": "Color of the inner shadow."},
                    {"key": "innerShadowOpacity", "label": "Inner shadow opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5, "requires": "innerShadow",
                     "description": "Opacity of the inner shadow."},
                    {"key": "innerShadowBlur", "label": "Inner shadow blur", "type": "number", "min": 0, "max": 40, "step": 0.5, "default": 6, "requires": "innerShadow",
                     "description": "Blur radius in pixels at 512px."},
                    {"key": "innerShadowOffsetX", "label": "Inner shadow X offset", "type": "number", "min": -32, "max": 32, "step": 1, "default": 4, "requires": "innerShadow",
                     "description": "Positive values cast the shadow to the right, darkening the left inside edges."},
                    {"key": "innerShadowOffsetY", "label": "Inner shadow Y offset", "type": "number", "min": -32, "max": 32, "step": 1, "default": 4, "requires": "innerShadow",
                     "description": "Positive values cast the shadow downward, darkening the top inside edges."},
                ],
            },
        ],
    },
    {
        "id": "color",
        "label": "Color",
        "effects": True,
        "collapsed": True,
        "settings": [
            {
                "type": "group",
                "id": "colorOverlay",
                "label": "Color overlay",
                "settings": [
                    {"key": "colorOverlay", "label": "Enable color overlay", "type": "bool", "default": False,
                     "description": "Tint the model with a color. Its alpha sets how strongly the color covers the model."},
                    {"key": "colorOverlayColor", "label": "Overlay color", "type": "rgba", "default": "#FF3B3B80", "requires": "colorOverlay",
                     "description": "Overlay color and opacity."},
                ],
            },
            {
                "type": "group",
                "id": "celShading",
                "label": "Cel shading",
                "settings": [
                    {"key": "celShading", "label": "Enable cel shading", "type": "bool", "default": False,
                     "description": "Flatten shading into a few hard-edged bands, like a cartoon."},
                    {"key": "celLevels", "label": "Cel bands", "type": "number", "min": 2, "max": 8, "step": 1, "default": 3, "requires": "celShading",
                     "description": "Number of brightness bands."},
                ],
            },
            {
                "type": "group",
                "id": "heatmap",
                "label": "Heatmap",
                "settings": [
                    {"key": "heatmap", "label": "Enable heatmap", "type": "bool", "default": False,
                     "description": "Recolor the model with a thermal-camera palette."},
                    {"key": "heatmapSource", "label": "Heatmap source", "type": "select", "default": "brightness", "options": [{"value": "brightness", "label": "Brightness"}, {"value": "depth", "label": "Depth (near is hot)"}], "requires": "heatmap",
                     "description": "What drives the heat: the shaded brightness, or how close each surface is to the camera."},
                ],
            },
            {
                "type": "group",
                "id": "duotone",
                "label": "Duotone",
                "settings": [
                    {"key": "duotone", "label": "Enable duotone", "type": "bool", "default": False,
                     "description": "Map brightness onto a gradient between two colors."},
                    {"key": "duotoneShadow", "label": "Duotone shadows", "type": "color", "default": "#1B1464", "requires": "duotone",
                     "description": "Color of the darkest areas."},
                    {"key": "duotoneHighlight", "label": "Duotone highlights", "type": "color", "default": "#FFC857", "requires": "duotone",
                     "description": "Color of the brightest areas."},
                ],
            },
            {
                "type": "group",
                "id": "tritone",
                "label": "Tritone",
                "settings": [
                    {"key": "tritone", "label": "Enable tritone", "type": "bool", "default": False,
                     "description": "Map brightness onto a gradient through three colors."},
                    {"key": "tritoneShadow", "label": "Tritone shadows", "type": "color", "default": "#14213D", "requires": "tritone",
                     "description": "Color of the darkest areas."},
                    {"key": "tritoneMidtone", "label": "Tritone midtones", "type": "color", "default": "#E5383B", "requires": "tritone",
                     "description": "Color of the middle tones."},
                    {"key": "tritoneHighlight", "label": "Tritone highlights", "type": "color", "default": "#FCECC9", "requires": "tritone",
                     "description": "Color of the brightest areas."},
                ],
            },
        ],
    },
    {
        "id": "stylize",
        "label": "Stylize",
        "effects": True,
        "collapsed": True,
        "settings": [
            {
                "type": "group",
                "id": "halftone",
                "label": "Halftone",
                "settings": [
                    {"key": "halftone", "label": "Enable halftone", "type": "bool", "default": False,
                     "description": "Print-style dot pattern; darker areas get bigger dots."},
                    {"key": "halftoneSize", "label": "Halftone dot size", "type": "number", "min": 2, "max": 32, "step": 1, "default": 6, "requires": "halftone",
                     "description": "Spacing of the dot grid in pixels at 512px."},
                    {"key": "halftoneStrength", "label": "Halftone strength", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.6, "requires": "halftone",
                     "description": "How much the dots darken and the gaps lighten."},
                ],
            },
            {
                "type": "group",
                "id": "dither",
                "label": "Dither",
                "settings": [
                    {"key": "dither", "label": "Enable dither", "type": "bool", "default": False,
                     "description": "Reduce colors with an ordered (Bayer) dither pattern."},
                    {"key": "ditherLevels", "label": "Dither levels", "type": "number", "min": 2, "max": 16, "step": 1, "default": 4, "requires": "dither",
                     "description": "Shades per color channel."},
                    {"key": "ditherScale", "label": "Dither pixel size", "type": "number", "min": 1, "max": 8, "step": 1, "default": 1, "requires": "dither",
                     "description": "Size of each dither pixel at 512px."},
                ],
            },
            {
                "type": "group",
                "id": "pixelate",
                "label": "Pixelate",
                "settings": [
                    {"key": "pixelate", "label": "Enable pixelate", "type": "bool", "default": False,
                     "description": "Downscale into large square pixels with nearest-neighbor sampling."},
                    {"key": "pixelSize", "label": "Pixel size", "type": "number", "min": 2, "max": 64, "step": 1, "default": 8, "requires": "pixelate",
                     "description": "Pixel block size at 512px."},
                ],
            },
            {
                "type": "group",
                "id": "chromaticAberration",
                "label": "Chromatic aberration",
                "settings": [
                    {"key": "chromaticAberration", "label": "Enable chromatic aberration", "type": "bool", "default": False,
                     "description": "Split the red and blue channels sideways for a glitchy look."},
                    {"key": "chromaticAmount", "label": "Aberration amount", "type": "number", "min": 1, "max": 32, "step": 1, "default": 4, "requires": "chromaticAberration",
                     "description": "Channel offset in pixels at 512px."},
                ],
            },
            {
                "type": "group",
                "id": "crt",
                "label": "CRT",
                "settings": [
                    {"key": "crt", "label": "Enable CRT", "type": "bool", "default": False,
                     "description": "Old TV look: scanlines, an RGB phosphor mask and screen curvature."},
                    {"key": "crtScanlines", "label": "CRT scanlines", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5, "requires": "crt",
                     "description": "Darkness of the scanlines and phosphor mask."},
                    {"key": "crtCurvature", "label": "CRT curvature", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.2, "requires": "crt",
                     "description": "How much the image bulges like a curved screen."},
                ],
            },
            {
                "type": "group",
                "id": "bloom",
                "label": "Bloom",
                "settings": [
                    {"key": "bloom", "label": "Enable bloom", "type": "bool", "default": False,
                     "description": "Make bright areas glow."},
                    {"key": "bloomThreshold", "label": "Bloom threshold", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.7, "requires": "bloom",
                     "description": "Only areas brighter than this glow."},
                    {"key": "bloomIntensity", "label": "Bloom intensity", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1, "requires": "bloom",
                     "description": "Strength of the glow."},
                    {"key": "bloomRadius", "label": "Bloom radius", "type": "number", "min": 1, "max": 64, "step": 1, "default": 12, "requires": "bloom",
                     "description": "Glow spread in pixels at 512px."},
                ],
            },
        ],
    },
    {
        "id": "depth",
        "label": "Depth",
        "effects": True,
        "collapsed": True,
        "settings": [
            {
                "type": "group",
                "id": "xray",
                "label": "X-ray",
                "settings": [
                    {"key": "xray", "label": "Enable X-ray", "type": "bool", "default": False,
                     "description": "Glowing see-through look: edges facing away from the camera are bright, the middle is faint."},
                    {"key": "xrayColor", "label": "X-ray color", "type": "color", "default": "#7FD4FF", "requires": "xray",
                     "description": "Color of the X-ray glow."},
                    {"key": "xrayFalloff", "label": "X-ray falloff", "type": "number", "min": 0.5, "max": 4, "step": 0.05, "default": 1.5, "requires": "xray",
                     "description": "Higher values keep the glow closer to the edges."},
                ],
            },
            {
                "type": "group",
                "id": "depthTint",
                "label": "Depth tint",
                "settings": [
                    {"key": "depthTint", "label": "Enable depth tint", "type": "bool", "default": False,
                     "description": "Tint parts further from the camera, like fog."},
                    {"key": "depthTintColor", "label": "Depth tint color", "type": "color", "default": "#6FA8FF", "requires": "depthTint",
                     "description": "Color the far parts fade toward."},
                    {"key": "depthTintStrength", "label": "Depth tint strength", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5, "requires": "depthTint",
                     "description": "How strongly the farthest parts are tinted."},
                ],
            },
            {
                "type": "group",
                "id": "depthOutline",
                "label": "Depth outline",
                "settings": [
                    {"key": "depthOutlineSize", "label": "Depth outline thickness", "type": "number", "min": 0, "max": 12, "step": 0.5, "default": 0,
                     "description": "Draw lines where parts overlap at different depths, in pixels at 512px. 0 disables them."},
                    {"key": "depthOutlineColor", "label": "Depth outline color", "type": "color", "default": "#000000", "requires": "depthOutlineSize",
                     "description": "Color of the depth outlines."},
                ],
            },
        ],
    },
    {
        "id": "vignette",
        "label": "Vignette",
        "effects": True,
        "collapsed": True,
        "settings": [
            {"key": "vignette", "label": "Enable vignette", "type": "bool", "default": False,
             "description": "Fade the borders of the image into a color."},
            {"key": "vignetteColor", "label": "Vignette color", "type": "color", "default": "#000000", "requires": "vignette",
             "description": "Color at the image borders."},
            {"key": "vignetteStrength", "label": "Vignette strength", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5, "requires": "vignette",
             "description": "How far the vignette reaches toward the center."},
            {"key": "vignetteOpacity", "label": "Vignette opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.6, "requires": "vignette",
             "description": "Opacity of the vignette at the corners."},
        ],
    },
    {
        "id": "text",
        "label": "Text",
        "effects": True,
        "collapsed": True,
        "settings": [
            {"key": "text", "label": "Text", "type": "text", "default": "", "maxLength": 120,
             "description": "Text drawn over the render, above every other effect. Leave empty for none. Type \\\\n for a new line."},
            {
                "type": "group",
                "id": "textFont",
                "label": "Font",
                "requires": "text",
                "settings": [
                    {"key": "textFont", "label": "Font", "type": "select", "default": "", "optionsSource": "fonts", "options": [{"value": "", "label": "Default"}],
                     "description": "Fonts installed on this computer, including Roblox Studio's fonts."},
                    {"key": "textSize", "label": "Text size", "type": "number", "min": 8, "max": 256, "step": 1, "default": 64,
                     "description": "Font size in pixels at 512px."},
                    {"key": "textWeight", "label": "Text weight", "type": "number", "min": 100, "max": 900, "step": 100, "default": 400,
                     "description": "100 is thin, 400 regular, 700 bold, 900 black. Uses the font's own weights when it has them."},
                    {"key": "textBold", "label": "Bold", "type": "bool", "default": False,
                     "description": "Adds 300 to the text weight."},
                    {"key": "textItalic", "label": "Italic", "type": "bool", "default": False,
                     "description": "Slant the text. Uses the font's italic style when it has one."},
                ],
            },
            {
                "type": "group",
                "id": "textLayout",
                "label": "Layout",
                "requires": "text",
                "settings": [
                    {"key": "textOffsetX", "label": "Text X offset", "type": "number", "min": -512, "max": 512, "step": 1, "default": 0,
                     "description": "Move text right in pixels at 512px. Drag the text in the Blender preview to set this."},
                    {"key": "textOffsetY", "label": "Text Y offset", "type": "number", "min": -512, "max": 512, "step": 1, "default": 0,
                     "description": "Move text down in pixels at 512px. Drag the text in the Blender preview to set this."},
                    {"key": "textRotation", "label": "Text rotation", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
                     "description": "Clockwise rotation in degrees."},
                    {"key": "textLetterSpacing", "label": "Letter spacing", "type": "number", "min": 0.5, "max": 3, "step": 0.05, "default": 1,
                     "description": "Space between letters. 1 is the font's normal spacing."},
                    {"key": "textLineSpacing", "label": "Line spacing", "type": "number", "min": 0.5, "max": 3, "step": 0.05, "default": 1,
                     "description": "Space between lines. 1 is the font's normal spacing."},
                ],
            },
            {
                "type": "group",
                "id": "textFill",
                "label": "Fill",
                "requires": "text",
                "settings": [
                    {"key": "textColor", "label": "Fill color", "type": "rgba", "default": "#FFFFFFFF",
                     "description": "Text color and opacity. Make it transparent for outline-only text."},
                    {"key": "textGradient", "label": "Enable gradient", "type": "bool", "default": False,
                     "description": "Fade the text fill into a second color."},
                    {"key": "textGradientColor", "label": "Gradient color", "type": "rgba", "default": "#FF8A00FF", "requires": "textGradient",
                     "description": "Color at the end of the gradient."},
                    {"key": "textGradientAngle", "label": "Gradient angle", "type": "number", "min": -180, "max": 180, "step": 1, "default": 90, "requires": "textGradient",
                     "description": "Direction of the gradient in degrees. 0 runs left to right, 90 top to bottom."},
                ],
            },
            {
                "type": "group",
                "id": "textDecoration",
                "label": "Decoration",
                "requires": "text",
                "settings": [
                    {"key": "textUnderline", "label": "Underline", "type": "bool", "default": False,
                     "description": "Draw a line under the text."},
                    {"key": "textStrikethrough", "label": "Strikethrough", "type": "bool", "default": False,
                     "description": "Draw a line through the text."},
                ],
            },
            {
                "type": "group",
                "id": "textOutline",
                "label": "Outline",
                "requires": "text",
                "settings": [
                    {"key": "textOutlineSize", "label": "Outline size", "type": "number", "min": 0, "max": 24, "step": 0.5, "default": 0,
                     "description": "Outline width in pixels at 512px. 0 disables it."},
                    {"key": "textOutlineColor", "label": "Outline color", "type": "rgba", "default": "#000000FF", "requires": "textOutlineSize",
                     "description": "Outline color and opacity."},
                ],
            },
            {
                "type": "group",
                "id": "textGlow",
                "label": "Glow",
                "requires": "text",
                "settings": [
                    {"key": "textGlow", "label": "Enable glow", "type": "bool", "default": False,
                     "description": "Draw a soft glow around the text."},
                    {"key": "textGlowColor", "label": "Glow color", "type": "rgba", "default": "#FFD966CC", "requires": "textGlow",
                     "description": "Glow color and opacity."},
                    {"key": "textGlowSize", "label": "Glow size", "type": "number", "min": 1, "max": 64, "step": 1, "default": 12, "requires": "textGlow",
                     "description": "Glow spread in pixels at 512px."},
                ],
            },
            {
                "type": "group",
                "id": "textShadow",
                "label": "Shadow",
                "requires": "text",
                "settings": [
                    {"key": "textShadow", "label": "Enable shadow", "type": "bool", "default": False,
                     "description": "Draw a shadow behind the text."},
                    {"key": "textShadowColor", "label": "Shadow color", "type": "rgba", "default": "#00000099", "requires": "textShadow",
                     "description": "Shadow color and opacity."},
                    {"key": "textShadowOffsetX", "label": "Shadow X offset", "type": "number", "min": -32, "max": 32, "step": 1, "default": 4, "requires": "textShadow",
                     "description": "Positive values move the shadow right."},
                    {"key": "textShadowOffsetY", "label": "Shadow Y offset", "type": "number", "min": -32, "max": 32, "step": 1, "default": 4, "requires": "textShadow",
                     "description": "Positive values move the shadow down."},
                    {"key": "textShadowBlur", "label": "Shadow blur", "type": "number", "min": 0, "max": 32, "step": 0.5, "default": 4, "requires": "textShadow",
                     "description": "Blur radius in pixels at 512px."},
                ],
            },
        ],
    },
    {
        "id": "geometry",
        "label": "Geometry",
        "settings": [
            {"key": "subdivision", "label": "Subdivision levels", "type": "number", "min": 0, "max": 3, "step": 1, "default": 0,
             "description": "Subdivision surface levels. Higher values are smoother and slower."},
            {"key": "smooth", "label": "Smooth shading", "type": "bool", "default": False,
             "description": "Merge split vertices and shade smooth instead of using the mesh's own normals."},
        ],
    },
    {
        "id": "cavity",
        "label": "Cavity",
        "settings": [
            {"key": "cavity", "label": "Enable cavity", "type": "bool", "default": True,
             "description": "Highlight ridges and darken valleys."},
            {"key": "worldRidge", "label": "World ridge", "type": "number", "min": 0, "max": 2.5, "step": 0.01, "default": 2, "requires": "cavity",
             "description": "World space ridge highlight strength."},
            {"key": "worldValley", "label": "World valley", "type": "number", "min": 0, "max": 2.5, "step": 0.01, "default": 1.5, "requires": "cavity",
             "description": "World space valley darkening strength."},
            {"key": "screenRidge", "label": "Screen ridge", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.15, "requires": "cavity",
             "description": "Screen space ridge highlight strength."},
            {"key": "screenValley", "label": "Screen valley", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.15, "requires": "cavity",
             "description": "Screen space valley darkening strength."},
            {"key": "minAngle", "label": "Minimum angle", "type": "number", "min": 0, "max": 180, "step": 1, "default": 35, "requires": "cavity",
             "description": "Ignore curves gentler than this many degrees. 0 keeps all cavity; 180 disables it."},
        ],
    },
]


def walk(items):
    """Every setting in a list of settings and nested groups, in display order."""
    for item in items:
        if item.get("type") == "group":
            yield from walk(item["settings"])
        else:
            yield item


SETTINGS = {setting["key"]: setting for section in SECTIONS for setting in walk(section["settings"])}
DEFAULTS = {key: setting["default"] for key, setting in SETTINGS.items()}
# Image effects run on the rendered pixels, so changing them never re-renders in Blender.
EFFECT_KEYS = frozenset(
    setting["key"] for section in SECTIONS if section.get("effects") for setting in walk(section["settings"])
)
HEX_COLOR = re.compile(r"^#?([0-9a-fA-F]{6})$")
HEX_RGBA = re.compile(r"^#?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$")
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")


def schema():
    return {"sections": SECTIONS, "defaults": DEFAULTS}


def normalize_value(setting, value):
    kind = setting["type"]
    if kind == "bool":
        return value if isinstance(value, bool) else setting["default"]
    if kind == "color":
        match = HEX_COLOR.match(value) if isinstance(value, str) else None
        return f"#{match.group(1).upper()}" if match else setting["default"]
    if kind == "rgba":
        match = HEX_RGBA.match(value) if isinstance(value, str) else None
        return f"#{match.group(1).upper()}{(match.group(2) or 'FF').upper()}" if match else setting["default"]
    if kind == "text":
        if not isinstance(value, str):
            return setting["default"]
        return CONTROL_CHARACTERS.sub("", value)[:setting.get("maxLength", 120)]
    if kind == "select":
        if not isinstance(value, str):
            return setting["default"]
        if "optionsSource" in setting:
            # Dynamic options (fonts) differ per machine; the renderer falls back when missing.
            return CONTROL_CHARACTERS.sub("", value)[:100]
        return value if any(option["value"] == value for option in setting["options"]) else setting["default"]
    if kind == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return setting["default"]
        return min(max(float(value), setting["min"]), setting["max"])
    return setting["default"]


def normalize(settings):
    """Merge defaults into a settings dict and clamp every value to its schema."""
    settings = settings if isinstance(settings, dict) else {}
    return {
        key: normalize_value(setting, settings.get(key, setting["default"]))
        for key, setting in SETTINGS.items()
    }


def hex_to_rgba(value):
    """Parse #RRGGBBAA into display-space floats."""
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4, 6))


def hex_to_rgb(value):
    """Parse #RRGGBB into display-space floats."""
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def srgb_to_linear(channel):
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4
