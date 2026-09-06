# Prism

Prism is a GPL-3.0-or-later desktop app for turning 3D models into polished images. Its Qt interface owns the workflow. A long-lived Blender process imports models and renders previews or final images.

## Status

This branch is a ground-up rewrite. The old Tauri application was intentionally removed in commit `e04aaa3`. Prism now imports a supported model into a persistent Blender worker, shows an Eevee preview, supports basic orbit/pan/zoom, exports images, and has offline `P1.` preset codes.

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

The first settings panel controls camera position, key/fill/world lighting, material roughness and metallic, smooth shading/subdivision, detail controls, output dimensions, and transparent output. Final export recognizes PNG, JPEG, WebP, and OpenEXR based on the chosen filename extension.

## License

Prism is licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).

For packaging instructions, see [docs/packaging.md](docs/packaging.md).
