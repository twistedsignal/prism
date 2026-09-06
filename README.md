# Prism

Prism is a local desktop app for importing a 3D model, styling a clean Blender Eevee render, and exporting PNG, JPEG, WebP, or EXR images.

It uses the Blender workflow in [modelrender](https://github.com/OttoHatt/modelrender) as a starting point. Prism and its Blender bridge are GPL-3.0-or-later.

## Development

Install Node 22+, pnpm, Rust, Tauri's platform prerequisites, and Blender on `PATH`.

```sh
pnpm install
pnpm dev
```

Prism copies imported models into its local project store. It invokes Blender in background mode for preview and export, so no model data is uploaded.

## Current scope

- `.blend`, `.fbx`, `.obj`, `.glb`, `.gltf`, `.stl`, Collada, PLY, Alembic, and USD imports where the installed Blender build supports them
- Eevee studio rendering with orbit camera, key/fill/world lights, transparent backgrounds, and a cavity control
- Project-local model copies and settings
- Compact `P1.` preset codes for sharing render settings

## License

GPL-3.0-or-later. The SPDX identifier appears in the package metadata and source headers. Full license text: https://www.gnu.org/licenses/gpl-3.0.txt.
