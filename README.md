# Prism

Prism is a GPL-3.0-or-later desktop app for turning 3D models into polished images. Its Qt interface owns the workflow. A long-lived Blender process imports models and renders previews or final images.

## Status

This branch is a ground-up rewrite. The old Tauri application was intentionally removed in commit `e04aaa3`. The first working slices establish the typed state model, versioned IPC, presets, and a PySide6 shell before the Blender render path lands.

## Development

Prism needs Python 3.12 or newer and Blender on `PATH`. Install the project with its development tools, then run the checks:

```sh
python -m pip install -e '.[dev]'
ruff check .
mypy src/prism
pytest
python -m prism.app.main
```

Prism supports `.blend`, `.glb`, `.gltf`, `.fbx`, `.obj`, and `.stl` in its first release. Blender performs all imports so format support follows the installed Blender version.

## License

Prism is licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).

