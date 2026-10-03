<div align="center">
  <img src="assets/icon.png" width="96" />
  <h1>Prism</h1>
  <p>Render Roblox Studio models into icons with Blender, right from a Studio plugin.</p>
</div>

Prism is a Roblox Studio ↔ Blender bridge. Select models in Studio and tweak the camera, lighting, outline, shadow and glow with a live preview. You can then save the icons to a folder or upload them straight to Roblox.

## Install

You need [Blender](https://www.blender.org/download/) 4.2 or newer and [Node.js](https://nodejs.org) 20 or newer. The installer sets up [raven](https://github.com/twistedsignal/raven) for uploads, walks you through creating a Roblox API key, starts the Prism backend at login and installs the Studio plugin.

**macOS and Linux (including Vinegar):**

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1 | iex
```

Prism checks GitHub for new releases. When one is out, the plugin offers to update. The backend then downloads the release, reinstalls itself and the plugin, and restarts. Restart Roblox Studio afterwards to load the new plugin. You can also check from **Settings → Check for updates**, or run the install command again.

To uninstall:

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash -s -- --uninstall
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1))) -Uninstall
```

Uninstalling leaves raven, your settings and your presets in place.

## Using it

1. Select one or more models, tools, accessories or parts in Studio. Prism adds them automatically and keeps previously added models and their settings.
2. Click a card to pick a model. Edit **This model** only, or **All** models at once.
3. Use **3D** for an instant Studio viewport, or **Blender** for the real render. Drag the preview to orbit and scroll to zoom. These gestures update the actual camera settings for the current editing scope. A loading circle shows when Prism is reading or rendering.
4. **Render** saves PNGs to your output folder. **Upload** sends them to Roblox and shows the asset ids. **Open folder** opens the output folder.

Presets are saved on your computer, so they work in every game. The **Settings** tab holds the output folder, render sizes, quality and the default upload creator.

### Limitations

- Prism first reads meshes and textures through Studio's editable APIs. If Studio cannot read them, the backend tries anonymous Asset Delivery, then Raven with your saved API key. Successful downloads and decoded meshes/images are cached on disk. Known foreign assets skip Studio editable reads. Denied legacy delivery routes are remembered for 24 hours, with temporary network failures retried after a minute; Raven recovery continues immediately. Assets that still cannot be recovered show a warning and use boxes or part color.
- Plugins can't read union (CSG) geometry, so unions are drawn as boxes.
- Classic shirts, pants and T-shirts render on R6/R15 body parts. Face decals, other decals and tiled Texture objects are composited over part color or mesh textures, preserving alpha and tint. Custom body shapes use a face projection of the classic template; Studio's layered-clothing cage deformation and Roblox material textures are not reproduced.

## How it works

```
Studio plugin ──HTTP 127.0.0.1:47821──▶ backend (runs inside Blender)
  reads content or sends asset IDs        downloads assets, builds OBJ, renders
  live preview (EditableImage)  ◀───────  RGBA pixels
                                          saves PNGs, uploads through raven
```

The HTTP backend runs in plain Python, using Blender's bundled interpreter when installed. It starts Blender only when scene preparation or rendering needs it, keeps the worker warm while you work, and shuts it down after 60 seconds without a scene or render job. The next job starts a fresh worker automatically. Settings, uploads and update checks keep working while Blender is stopped.

It only listens on `127.0.0.1` and rejects browser requests. It starts at login through a systemd user service on Linux, a LaunchAgent on macOS, or a Task Scheduler task on Windows. Existing installations migrate their startup entry on the first launch after updating to v0.5.0.

| File | Location |
|---|---|
| Settings and presets | `~/.config/prism` · `~/Library/Application Support/Prism` · `%APPDATA%\Prism` |
| Backend | `~/.local/share/prism` · `~/Library/Application Support/Prism` · `%LOCALAPPDATA%\Prism` |
| Logs | `journalctl --user -u prism` · `~/Library/Logs/Prism.log` · `%LOCALAPPDATA%\Prism\prism.log` |

## Upgrading from v0.2.0

Edit your existing personal API key in the Creator Dashboard and add **Legacy Assets > Manage** (`legacy-asset:manage`). Keep **Assets > Read and Write** enabled. Prism's updater upgrades Raven automatically and enables its download command; you do not need to replace your key. If the key is missing permissions, rendering uses placeholders with a warning. After fixing permissions, select the model again to retry recovery.

Completed renders use a 64 MB memory cache in the Blender worker, shared by previews, exports and uploads. Changing a model, camera, render settings, output size or antialiasing selects a different cache entry. Worker shutdown releases this cache and imported models; prepared scenes remain on disk for the next worker.

Auto-3d is enabled by default in the plugin's Settings tab. It hides the 3D/Blender picker, shows the Studio viewport immediately when you edit the camera or model settings, and switches to the matching Blender preview when rendering finishes. Turn it off to choose either view manually. The preference is saved per Studio user.

Image effects reuse the rendered image, so saturation, contrast, brightness, outline, shadow and glow edits skip Blender entirely. Silhouettes and blurred masks are reused when only colors, opacity or shadow offsets change. Cavity angle changes reuse the color, base and normals passes; turning cavity off reuses the base pass. Intermediate PNGs use no compression. These additional worker caches are bounded to 112 MiB and released when the worker shuts down.

R15 classic clothing uses Roblox's compositing UV maps and preserves the body meshes' original UV islands, including wrists, knees and ankles. Primitive fallback parts sample the sleeve or pant seam at internal joints instead of repeating the shoulder or hip cap.

The backend supports FileMesh v1, v2, v3, v4, and v7. Compressed v7 meshes use Blender's bundled Draco decoder; official Blender builds include it. No extra Python package or export dialog is required. Downloads respect the key's access to each asset.

## Development

Tools are managed with [Rokit](https://github.com/rojo-rbx/rokit):

```sh
rokit install
wally install
scripts/build.bash   # build/Prism.rbxm
scripts/dev.bash     # build into your Studio Plugins folder and rebuild on change
selene src
lune run tests/selection.luau
lune run tests/auto3d.luau
lune run tests/drag.luau
lune run tests/camera.luau
lune run tests/preview-input.luau
lune run tests/asset-routing.luau
python3 -m unittest discover -s tests -p 'test_*.py'
PRISM_TEST_BLENDER=/path/to/blender python3 -m unittest discover -s tests -p 'test_worker.py'
```

`dev.bash` finds the Plugins folder of a Vinegar flatpak or native prefix, macOS or Windows. Set `PRISM_PLUGINS_DIR` to override it.

Run the backend from the checkout:

```sh
python3 backend/main.py serve --blender /path/to/blender --port 47821
```

Render an OBJ directly, without the server:

```sh
blender --background --factory-startup --python backend/renderer.py -- model.obj out.png --settings settings.json --size 512
```

Render settings are defined once in `backend/schema.py`. The plugin builds its sliders, toggles and color pickers from that schema.

To test the installer against a local checkout, build the plugin first, then run:

```sh
PRISM_SOURCE="$PWD" bash install.sh
```

Releases are published by `.github/workflows/release.yml` when the version in `wally.toml` changes.
