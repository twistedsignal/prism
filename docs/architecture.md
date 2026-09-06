# Architecture

Prism has two processes. The PySide6 application owns user input, settings, preview scheduling, and image presentation. Blender owns model import, scene data, and renders. Blender never runs on the Qt UI thread.

The application starts one Blender worker in background mode. Commands and small replies use UTF-8 JSON Lines over standard input and output. Every message has protocol version `v`, request `id`, a `type`, and a JSON object `payload`. Worker diagnostics only use stderr.

The UI changes a typed `RenderSettings` instance. `PreviewScheduler` accepts the newest requested state while a render is in progress, then dispatches only that newest state once the worker is available. It uses a low interaction profile while dragging and schedules a higher-quality frame after a short idle delay.

Preview pixels use a one-shot shared-memory RGBA buffer. Blender reports the shared-memory name, dimensions, stride, generation, and render duration. Qt maps that memory into a `QImage`, copies it into a `QPixmap`, then closes and unlinks the buffer. This avoids PNG encoding and decoding on the preview path.

On shutdown, Prism cancels queued preview work, requests worker shutdown, closes standard streams, then terminates the child only after a timeout. A crash turns the worker state into `FAILED` and lets the UI show a plain-language recovery action.

## Protocol v1

```json
{"v":1,"id":7,"type":"worker.hello","payload":{}}
{"v":1,"id":7,"type":"worker.ready","payload":{"blender_version":"4.2"}}
```

Implemented command names are `worker.hello`, `worker.shutdown`, `model.import`, `camera.frame`, `preview.render`, and `output.render`. Replies use command-specific success types or `*.error`. Preview and output replies include elapsed milliseconds. Error payloads contain a stable `code`, an optional preview generation, and a user-facing `message`; tracebacks remain in worker stderr.
