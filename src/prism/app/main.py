"""Prism application entry point."""

from __future__ import annotations

import sys
from dataclasses import asdict, replace
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction, QCloseEvent
from PySide6.QtWidgets import (
    QApplication,
    QDockWidget,
    QFileDialog,
    QMainWindow,
    QMessageBox,
    QToolBar,
)

from prism.core.model_types import validate_model_path
from prism.core.presets import PresetError, decode, encode
from prism.core.settings import CameraSettings, Projection, RenderEngine, RenderSettings
from prism.renderer.client import BlenderWorkerClient, WorkerState
from prism.renderer.discovery import discover_blender
from prism.renderer.protocol import Message
from prism.renderer.scheduler import PreviewQuality, PreviewRequest, PreviewScheduler
from prism.renderer.shared_memory import take_preview_frame
from prism.ui.settings_panel import SettingsPanel
from prism.ui.viewport import ViewportWidget


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Prism")
        self.resize(1280, 800)
        self._close_after_worker = False
        self._settings = RenderSettings()
        self._viewport = ViewportWidget()
        self._viewport.set_camera(self._settings.camera)
        self._viewport.camera_changed.connect(self._set_camera)
        self._viewport.frame_requested.connect(self._frame_model)
        self._scheduler = PreviewScheduler(self._dispatch_preview)
        self._idle_timer = QTimer(self)
        self._idle_timer.setSingleShot(True)
        self._idle_timer.setInterval(220)
        self._idle_timer.timeout.connect(self._request_idle_preview)
        bundle_root = getattr(sys, "_MEIPASS", None)
        if isinstance(bundle_root, str):
            worker_script = Path(bundle_root) / "prism" / "blender_worker" / "main.py"
        else:
            worker_script = Path(__file__).parents[1] / "blender_worker" / "main.py"
        self._worker = BlenderWorkerClient(worker_script, self)
        self._worker.state_changed.connect(self._on_worker_state)
        self._worker.message_received.connect(self._on_worker_message)
        self._worker.user_error.connect(self._show_worker_error)
        self._panel = SettingsPanel()
        self._panel.camera_changed.connect(self._set_camera_values)
        self._panel.projection_changed.connect(self._set_projection)
        self._panel.lighting_changed.connect(self._set_lighting)
        self._panel.material_changed.connect(self._set_material)
        self._panel.geometry_changed.connect(self._set_geometry)
        self._panel.cavity_changed.connect(self._set_cavity)
        self._panel.output_changed.connect(self._set_output)
        self._panel.set_settings(self._settings)
        self.setCentralWidget(self._viewport)
        self.addDockWidget(Qt.DockWidgetArea.RightDockWidgetArea, self._dock_for_panel())
        toolbar = QToolBar("Main", self)
        self.addToolBar(toolbar)
        import_action = QAction("Import model", self)
        import_action.triggered.connect(self._choose_model)
        toolbar.addAction(import_action)
        export_action = QAction("Export image", self)
        export_action.triggered.connect(self._export_image)
        toolbar.addAction(export_action)
        copy_preset_action = QAction("Copy preset", self)
        copy_preset_action.triggered.connect(self._copy_preset)
        toolbar.addAction(copy_preset_action)
        paste_preset_action = QAction("Paste preset", self)
        paste_preset_action.triggered.connect(self._paste_preset)
        toolbar.addAction(paste_preset_action)
        restart_action = QAction("Restart Blender", self)
        restart_action.triggered.connect(self._restart_worker)
        toolbar.addAction(restart_action)
        blender = discover_blender()
        if blender is None:
            self._viewport.setText("Blender was not found on PATH.")
        else:
            self._worker.start(blender)

    def _dock_for_panel(self) -> QDockWidget:
        dock = QDockWidget("Settings", self)
        dock.setWidget(self._panel)
        dock.setMinimumWidth(280)
        return dock

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._worker.state is not WorkerState.STOPPED:
            self._close_after_worker = True
            self._viewport.setText("Stopping Blender…")
            self._worker.shutdown()
            event.ignore()
            return
        event.accept()

    def _choose_model(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Import 3D model",
            "",
            "3D models (*.blend *.glb *.gltf *.fbx *.obj *.stl)",
        )
        if path:
            try:
                model_path = validate_model_path(Path(path))
            except ValueError as error:
                self._show_worker_error(str(error))
                return
            self._viewport.setText("Importing model…")
            self._worker.send("model.import", {"path": str(model_path)})

    def _export_image(self) -> None:
        path, _ = QFileDialog.getSaveFileName(
            self,
            "Export image",
            "render.png",
            "Images (*.png *.jpg *.jpeg *.webp *.exr)",
        )
        if path:
            self._worker.send("output.render", {"output_path": path, **asdict(self._settings)})

    def _copy_preset(self) -> None:
        QApplication.clipboard().setText(encode(self._settings))

    def _paste_preset(self) -> None:
        try:
            self._settings = decode(QApplication.clipboard().text())
        except PresetError as error:
            self._show_worker_error(str(error))
            return
        self._viewport.set_camera(self._settings.camera)
        self._panel.set_settings(self._settings)
        self._request_idle_preview()

    def _on_worker_state(self, state: str) -> None:
        if state == WorkerState.READY.value:
            self._viewport.setText("Import a model to begin")
        elif state == WorkerState.STOPPED.value and self._close_after_worker:
            self.close()

    def _on_worker_message(self, message: Message) -> None:
        if message.type in {"model.imported", "camera.framed"}:
            target = message.payload.get("frame_target")
            distance = message.payload.get("frame_distance")
            if isinstance(target, list) and len(target) == 3 and isinstance(distance, (int, float)):
                self._settings = replace(
                    self._settings,
                    camera=replace(
                        self._settings.camera,
                        target_x=float(target[0]),
                        target_y=float(target[1]),
                        target_z=float(target[2]),
                        distance=float(distance),
                    ),
                )
                self._viewport.set_camera(self._settings.camera)
            self._viewport.setText("Rendering preview…")
            self._request_idle_preview()
        elif message.type == "preview.frame":
            try:
                if message.payload.get("transport") == "shared-memory":
                    self._viewport.set_pixmap(take_preview_frame(message.payload))
                else:
                    self._viewport.set_frame(str(message.payload["path"]))
            except (KeyError, OSError, ValueError) as error:
                self._show_worker_error(f"Prism could not display the preview: {error}")
            self._scheduler.complete(int(message.payload.get("generation", -1)))
            elapsed = message.payload.get("elapsed_ms")
            if isinstance(elapsed, (int, float)):
                self.statusBar().showMessage(f"Preview {elapsed:.0f} ms", 1_500)
        elif message.type == "output.rendered":
            elapsed = message.payload.get("elapsed_ms")
            suffix = f" in {elapsed:.0f} ms" if isinstance(elapsed, (int, float)) else ""
            self.statusBar().showMessage(f"Exported {message.payload['path']}{suffix}", 5_000)
        elif message.type.endswith(".error"):
            generation = message.payload.get("generation")
            if isinstance(generation, int):
                self._scheduler.complete(generation)
            self._show_worker_error(
                str(message.payload.get("message", "Blender could not complete that request."))
            )

    def _show_worker_error(self, message: str) -> None:
        QMessageBox.warning(self, "Prism", message)

    def _restart_worker(self) -> None:
        blender = discover_blender()
        if blender is None:
            self._show_worker_error("Blender was not found on PATH.")
            return
        if self._worker.state is WorkerState.FAILED:
            self._worker.restart(blender)
        elif self._worker.state is WorkerState.STOPPED:
            self._worker.start(blender)

    def _set_camera(self, camera: CameraSettings, interacting: bool) -> None:
        self._settings = replace(self._settings, camera=camera)
        if interacting:
            self._scheduler.request(self._settings, PreviewQuality.INTERACTION)
            self._idle_timer.start()
        else:
            self._request_idle_preview()

    def _set_camera_values(
        self, yaw: float, pitch: float, distance: float, roll: float, field_of_view: float
    ) -> None:
        camera = replace(
            self._settings.camera,
            yaw_degrees=yaw,
            pitch_degrees=pitch,
            distance=distance,
            roll_degrees=roll,
            field_of_view_degrees=field_of_view,
        )
        self._viewport.set_camera(camera)
        self._set_camera(camera, False)

    def _set_projection(self, orthographic: bool) -> None:
        projection = Projection.ORTHOGRAPHIC if orthographic else Projection.PERSPECTIVE
        camera = replace(self._settings.camera, projection=projection)
        self._viewport.set_camera(camera)
        self._set_camera(camera, False)

    def _set_lighting(self, key: float, fill: float, world: float) -> None:
        self._settings = replace(
            self._settings,
            lighting=replace(
                self._settings.lighting, key_energy=key, fill_energy=fill, world_strength=world
            ),
        )
        self._request_idle_preview()

    def _set_material(self, original: bool, roughness: float, metallic: float) -> None:
        self._settings = replace(
            self._settings,
            material=replace(
                self._settings.material,
                use_original=original,
                roughness=roughness,
                metallic=metallic,
            ),
        )
        self._request_idle_preview()

    def _set_geometry(self, subdivision: int, smooth: bool) -> None:
        self._settings = replace(
            self._settings,
            geometry=replace(
                self._settings.geometry, subdivision_level=subdivision, smooth_shading=smooth
            ),
        )
        self._request_idle_preview()

    def _set_cavity(self, enabled: bool, ridge: float, valley: float) -> None:
        self._settings = replace(
            self._settings,
            cavity=replace(
                self._settings.cavity, enabled=enabled, ridge_strength=ridge, valley_strength=valley
            ),
        )
        self._request_idle_preview()

    def _set_output(self, width: int, height: int, transparent: bool, engine: str) -> None:
        self._settings = replace(
            self._settings,
            output=replace(
                self._settings.output,
                width=width,
                height=height,
                transparent_background=transparent,
                engine=RenderEngine(engine),
            ),
        )
        self._request_idle_preview()

    def _frame_model(self) -> None:
        self._worker.send("camera.frame", {})

    def _request_idle_preview(self) -> None:
        self._scheduler.request(self._settings, PreviewQuality.IDLE)

    def _dispatch_preview(self, request: PreviewRequest) -> None:
        size = (
            384
            if request.quality is PreviewQuality.INTERACTION
            else max(request.settings.output.width, request.settings.output.height)
        )
        payload = asdict(request.settings)
        payload["output"] = {**payload["output"], "width": size, "height": size}
        payload["generation"] = request.generation
        self._worker.send("preview.render", payload)


def main() -> int:
    application = QApplication(sys.argv)
    application.setApplicationName("Prism")
    window = MainWindow()
    window.show()
    return application.exec()


if __name__ == "__main__":
    raise SystemExit(main())
