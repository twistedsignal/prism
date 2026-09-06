from pathlib import Path

import pytest

from prism.core.model_types import validate_model_path


def test_validate_model_path_accepts_supported_fixture() -> None:
    assert validate_model_path(Path("tests/fixtures/cube.obj")).suffix == ".obj"


@pytest.mark.parametrize("path", [Path("missing.obj"), Path("pyproject.toml")])
def test_validate_model_path_rejects_invalid_inputs(path: Path) -> None:
    with pytest.raises(ValueError):
        validate_model_path(path)
