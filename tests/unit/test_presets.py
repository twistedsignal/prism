import pytest

from prism.core.presets import PresetError, decode, encode
from prism.core.settings import CameraSettings, MaterialSettings, RenderSettings


def test_preset_is_deterministic_and_round_trips() -> None:
    settings = RenderSettings()
    code = encode(settings)
    assert code.startswith("P1.")
    assert encode(settings) == code
    assert decode(code) == settings


def test_fully_populated_preset_round_trips() -> None:
    settings = RenderSettings(
        camera=CameraSettings(yaw_degrees=-120, pitch_degrees=40, distance=12),
        material=MaterialSettings(use_original=False, roughness=0.12, metallic=0.9),
    )
    assert decode(encode(settings)) == settings


@pytest.mark.parametrize("code", ["P0.nope", "P1.not-valid", ""])
def test_invalid_preset_is_user_safe(code: str) -> None:
    with pytest.raises(PresetError):
        decode(code)
