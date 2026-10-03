<div align="center">
  <img src="assets/icon.png" width="96" />
  <h1>Prism</h1>
  <p>Render Roblox Studio models into icons with Blender, right from a Studio plugin.</p>
</div>

#### Please ⭐ the repo if you like it!!

Select models in Studio, adjust the camera and effects, then save PNGs or upload them to Roblox. Blender handles the final preview and render.

## Install

You need [Blender](https://www.blender.org/download/) 4.2 or newer and [Node.js](https://nodejs.org) 20 or newer. The installer adds the Studio plugin, backend and [Raven](https://github.com/twistedsignal/raven), then helps you set up a Roblox API key for assets and uploads.

On macOS or Linux, including Vinegar:

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash
```

On Windows, run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1 | iex
```

## Use Prism

1. Select models, tools, accessories or parts in Studio. Click a card in Prism to work on one of them.
2. Adjust the camera and settings. Drag the preview to orbit, scroll to zoom, or drag over text in the Blender preview to move it. Studio text follows your mouse, then the Blender render replaces it. Choose **This model** or **All** to set the editing scope.
3. Click **Render** to save PNGs to your output folder. Click **Upload** to send them to Roblox as Decals. Prism shows the image IDs you can use in `ImageLabel.Image`.

The plugin has outlines, shadows, glow, color and depth effects, and text. Presets are saved locally. Prism also remembers a model's settings when you deselect and reselect it.

## Updates and removal

Prism prompts you when a new release is available. After an update, restart Roblox Studio to load the new plugin. You can also use **Settings → Check for updates** or run the installer again.

To uninstall on macOS or Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/twistedsignal/prism/main/install.sh | bash -s -- --uninstall
```

To uninstall on Windows:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/twistedsignal/prism/main/install.ps1))) -Uninstall
```

Uninstalling removes the plugin, backend and cache. It keeps your settings, presets and Raven installation.

## Common problems

- If Prism says **HTTP access blocked**, allow it to reach `127.0.0.1` under **Plugins → Manage Plugins**.
- If an asset cannot be downloaded, Prism shows a warning and uses a box or plain color. Check the API key permissions, then select the model again.
- Studio plugins cannot read union geometry, so Prism draws unions as boxes.

## How it works

```
Studio plugin ──HTTP 127.0.0.1:47821──▶ backend (runs inside Blender)
  reads content or sends asset IDs        downloads assets, builds OBJ, renders
  live preview (EditableImage)  ◀───────  RGBA pixels
                                          saves PNGs, uploads through raven
```

The HTTP backend runs in plain Python, using Blender's bundled interpreter when installed. It starts Blender only when scene preparation or rendering needs it, keeps the worker warm while you work, and shuts it down after 60 seconds without a scene or render job. The next job starts a fresh worker automatically. Settings, uploads and update checks keep working while Blender is stopped.

It only listens on `127.0.0.1` and rejects browser requests. It starts at login through a systemd user service on Linux, a LaunchAgent on macOS, or a Task Scheduler task on Windows.

| File | Location |
|---|---|
| Settings and presets | `~/.config/prism` · `~/Library/Application Support/Prism` · `%APPDATA%\Prism` |
| Backend | `~/.local/share/prism` · `~/Library/Application Support/Prism` · `%LOCALAPPDATA%\Prism` |
| Cache | `~/.cache/prism` · `~/Library/Caches/Prism` · `%LOCALAPPDATA%\Prism\cache` |
| Logs | `journalctl --user -u prism` · `~/Library/Logs/Prism.log` · `%LOCALAPPDATA%\Prism\prism.log` |

### Rendering details

Your Raven API key needs **Assets > Read and Write** and **Legacy Assets > Manage** (`legacy-asset:manage`); the installer checks both. If the key is missing permissions, rendering uses placeholders with a warning. After fixing permissions, select the model again to retry recovery.

Completed renders use a 16 MiB memory cache in the Blender worker, shared by previews, exports and uploads. Changing a model, camera, render settings, output size or antialiasing selects a different cache entry. Blender keeps the two most recently rendered models loaded; older models are imported again from prepared scenes on disk when needed. Worker shutdown releases these caches and imported models.

Auto-3D is enabled by default in the plugin's Settings tab. It hides the 3D/Blender picker, shows the Studio viewport immediately when you edit the camera or model settings, and switches to the matching Blender preview when rendering finishes. Turn it off to choose either view manually. The preference is saved per Studio user.

Image effects reuse the rendered image, so every effect edit skips Blender entirely while its base render is cached. Cel shading, X-ray and the depth effects add one extra pass each (unlit color, surface normals or camera depth); text renders in its own small scene. These passes are cached until their memory budget fills. Silhouettes and blurred masks are reused when only colors, opacity or shadow offsets change. Cavity angle changes reuse the color, base and normals passes; turning cavity off reuses the base pass. Intermediate PNGs use no compression. These additional worker caches are bounded to 48 MiB and released when the worker shuts down.

R15 classic clothing uses Roblox's compositing UV maps and preserves the body meshes' original UV islands, including wrists, knees and ankles. Primitive fallback parts sample the sleeve or pant seam at internal joints instead of repeating the shoulder or hip cap.

The Lighting section's **Sync Lighting** button copies the place's global lighting into the
current edit scope. It estimates sun or moon direction and strength, ambient light, color shifts,
exposure, specular highlights and cast shadows for each model's pivot, stance and camera.
This is a one-time sync; click again after changing the place lighting or the render view.
Sky reflections, atmosphere, local lights and Roblox post-processing are not reproduced.

Unions render from their serialized geometry, including stored colors when `UsePartColor` is off.
Prism regenerates a temporary unparented Union to recover cloud-backed geometry, then destroys it.
The CSG decoder supports legacy CSGMDLV5 and SolidMesh. Unsupported geometry falls back to a box
with a warning. Roblox can change these undocumented formats between Studio releases.

The backend supports FileMesh v1, v2, v3, v4, and v7. Compressed v7 meshes use Blender's bundled Draco decoder; official Blender builds include it. No extra Python package or export dialog is required. Downloads respect the key's access to each asset.

## Development

Tools are managed with [Rokit](https://github.com/rojo-rbx/rokit):

```sh
rokit install
wally install
scripts/build.bash   # build/Prism.rbxm
scripts/dev.bash     # build into your Studio Plugins folder and rebuild on change
scripts/test.bash    # selene, every Luau and Python test, installer checks
PRISM_TEST_BLENDER=/path/to/blender python3 -m unittest discover -s tests -p 'test_worker.py'
```

The Python tests need `numpy`. CI runs `scripts/test.bash` on every push and pull request, and releases only publish when it passes.

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

Releases are published by `.github/workflows/release.yml` when the version in `wally.toml` changes. The release commit's message becomes the release notes shown in the plugin's update prompt.

## License

Prism is released under the [MIT License](LICENSE). The meshes in `backend/clothing/` and `backend/primitives/` come from Roblox Studio and belong to Roblox Corporation.
