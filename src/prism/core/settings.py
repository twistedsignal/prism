"""Stable render settings independent of Blender scene internals."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class Projection(StrEnum):
    PERSPECTIVE = "perspective"
    ORTHOGRAPHIC = "orthographic"


class RenderEngine(StrEnum):
    EEVEE = "eevee"
    CYCLES = "cycles"


@dataclass(frozen=True)
class Color:
    red: float = 0.055
    green: float = 0.063
    blue: float = 0.086

    def __post_init__(self) -> None:
        if not all(0.0 <= value <= 1.0 for value in (self.red, self.green, self.blue)):
            raise ValueError("Color channels must be between 0 and 1.")


@dataclass(frozen=True)
class CameraSettings:
    target_x: float = 0.0
    target_y: float = 0.0
    target_z: float = 0.0
    yaw_degrees: float = 35.0
    pitch_degrees: float = 25.0
    roll_degrees: float = 0.0
    distance: float = 4.0
    field_of_view_degrees: float = 50.0
    projection: Projection = Projection.PERSPECTIVE
    orthographic_scale: float = 4.0

    def __post_init__(self) -> None:
        if not self.distance >= 0.01:
            raise ValueError("Camera distance must be positive.")
        if not 1.0 <= self.field_of_view_degrees <= 179.0:
            raise ValueError("Field of view must be between 1 and 179 degrees.")
        if not self.orthographic_scale >= 0.01:
            raise ValueError("Orthographic scale must be positive.")


@dataclass(frozen=True)
class OutputSettings:
    width: int = 1024
    height: int = 1024
    transparent_background: bool = False
    background: Color = field(default_factory=Color)
    engine: RenderEngine = RenderEngine.EEVEE

    def __post_init__(self) -> None:
        if not 1 <= self.width <= 16384 or not 1 <= self.height <= 16384:
            raise ValueError("Output dimensions must be between 1 and 16384 pixels.")


@dataclass(frozen=True)
class LightingSettings:
    key_energy: float = 1100.0
    fill_energy: float = 260.0
    world_strength: float = 1.0


@dataclass(frozen=True)
class MaterialSettings:
    use_original: bool = True
    base_color: Color = field(default_factory=lambda: Color(0.8, 0.8, 0.8))
    roughness: float = 0.45
    metallic: float = 0.0

    def __post_init__(self) -> None:
        if not 0.0 <= self.roughness <= 1.0 or not 0.0 <= self.metallic <= 1.0:
            raise ValueError("Material roughness and metallic must be between 0 and 1.")


@dataclass(frozen=True)
class GeometrySettings:
    subdivision_level: int = 0
    smooth_shading: bool = True

    def __post_init__(self) -> None:
        if not 0 <= self.subdivision_level <= 6:
            raise ValueError("Subdivision level must be between 0 and 6.")


@dataclass(frozen=True)
class CavitySettings:
    enabled: bool = True
    ridge_strength: float = 0.35
    valley_strength: float = 0.65
    distance: float = 0.5
    ambient_occlusion: float = 0.5


@dataclass(frozen=True)
class RenderSettings:
    camera: CameraSettings = field(default_factory=CameraSettings)
    output: OutputSettings = field(default_factory=OutputSettings)
    lighting: LightingSettings = field(default_factory=LightingSettings)
    material: MaterialSettings = field(default_factory=MaterialSettings)
    geometry: GeometrySettings = field(default_factory=GeometrySettings)
    cavity: CavitySettings = field(default_factory=CavitySettings)
