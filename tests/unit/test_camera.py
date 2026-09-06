from prism.core.camera import orbit, pan, zoom
from prism.core.settings import CameraSettings, CavitySettings


def test_orbit_clamps_pitch() -> None:
    camera = orbit(CameraSettings(pitch_degrees=88.0), 10.0, -20.0)
    assert camera.pitch_degrees == 89.0
    assert camera.yaw_degrees == 31.5


def test_zoom_is_exponential_and_positive() -> None:
    assert zoom(CameraSettings(distance=4.0), 1000).distance < 4.0
    assert zoom(CameraSettings(distance=0.01), 100000).distance == 0.01


def test_pan_moves_camera_target() -> None:
    camera = pan(CameraSettings(distance=5.0, yaw_degrees=0.0), 50.0, 20.0)
    assert camera.target_x < 0.0
    assert camera.target_z > 0.0


def test_cavity_rejects_invalid_radius() -> None:
    import pytest

    with pytest.raises(ValueError):
        CavitySettings(distance=0.0)
