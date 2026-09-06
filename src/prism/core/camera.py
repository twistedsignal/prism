"""Pure camera interaction math used by the viewport."""

from __future__ import annotations

import math
from dataclasses import replace

from prism.core.settings import CameraSettings


def orbit(camera: CameraSettings, delta_x: float, delta_y: float) -> CameraSettings:
    pitch = max(-89.0, min(89.0, camera.pitch_degrees - delta_y * 0.35))
    return replace(camera, yaw_degrees=camera.yaw_degrees - delta_x * 0.35, pitch_degrees=pitch)


def zoom(camera: CameraSettings, wheel_delta: float) -> CameraSettings:
    return replace(camera, distance=max(0.01, camera.distance * math.exp(-wheel_delta * 0.001)))


def pan(camera: CameraSettings, delta_x: float, delta_y: float) -> CameraSettings:
    scale = camera.distance * 0.002
    yaw = math.radians(camera.yaw_degrees)
    right_x, right_y = math.cos(yaw), -math.sin(yaw)
    return replace(
        camera,
        target_x=camera.target_x - delta_x * scale * right_x,
        target_y=camera.target_y - delta_x * scale * right_y,
        target_z=camera.target_z + delta_y * scale,
    )
