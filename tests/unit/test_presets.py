import pytest

from prism.core.presets import PresetError, decode, encode
from prism.core.settings import RenderSettings


def test_preset_is_deterministic_and_round_trips() -> None:
    settings = RenderSettings()
    code = encode(settings)
    assert code.startswith("P1.")
    assert encode(settings) == code
    assert decode(code) == settings


@pytest.mark.parametrize("code", ["P0.nope", "P1.not-valid", ""])
def test_invalid_preset_is_user_safe(code: str) -> None:
    with pytest.raises(PresetError):
        decode(code)
