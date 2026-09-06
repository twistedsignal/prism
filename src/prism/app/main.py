"""Prism application entry point."""

from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QAction, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QFileDialog,
    QLabel,
    QMainWindow,
    QMessageBox,
    QSplitter,
    QToolBar,
    QVBoxLayout,
    QWidget,
)

from prism.renderer.client import BlenderWorkerClient, WorkerState
from prism.renderer.discovery import discover_blender
from prism.renderer.protocol import Message


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Prism")
        self.resize(1280, 800)
        self._viewport = QLabel("Starting Blender…")
        self._viewport.setObjectName("viewport")
        self._viewport.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._viewport.setMinimumSize(640, 480)
        self._viewport.setStyleSheet("background: #171923; color: #c7cad8;")
        worker_script = Path(__file__).parents[1] / "blender_worker" / "main.py"
        self._worker = BlenderWorkerClient(worker_script, self)
        self._worker.state_changed.connect(self._on_worker_state)
        self._worker.message_received.connect(self._on_worker_message)
        self._worker.user_error.connect(self._show_worker_error)
        sidebar = QWidget()
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.addWidget(
            QLabel(
                "Model\n\nCamera\n\nLighting\n\nMaterial\n\nGeometry\n\nDetail / Cavity\n\nOutput"
            )
        )
        sidebar_layout.addStretch(1)
        split = QSplitter()
        split.addWidget(self._viewport)
        split.addWidget(sidebar)
        split.setSizes([960, 320])
        self.setCentralWidget(split)
        toolbar = QToolBar("Main", self)
        self.addToolBar(toolbar)
        import_action = QAction("Import model", self)
        import_action.triggered.connect(self._choose_model)
        toolbar.addAction(import_action)
        export_action = QAction("Export image", self)
        export_action.triggered.connect(self._export_image)
        toolbar.addAction(export_action)
        blender = discover_blender()
        if blender is None:
            self._viewport.setText("Blender was not found on PATH.")
        else:
            self._worker.start(blender)

    def closeEvent(self, event: object) -> None:
        self._worker.shutdown()
        super().closeEvent(event)  # type: ignore[arg-type]

    def _choose_model(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Import 3D model",
            "",
            "3D models (*.blend *.glb *.gltf *.fbx *.obj *.stl)",
        )
        if path:
            self._viewport.setText("Importing model…")
            self._worker.send("model.import", {"path": path})

    def _export_image(self) -> None:
        path, _ = QFileDialog.getSaveFileName(
            self, "Export image", "render.png", "PNG image (*.png)"
        )
        if path:
            self._worker.send(
                "output.render", {"output_path": path, "output": {"width": 1024, "height": 1024}}
            )

    def _on_worker_state(self, state: str) -> None:
        if state == WorkerState.READY.value:
            self._viewport.setText("Import a model to begin")

    def _on_worker_message(self, message: Message) -> None:
        if message.type == "model.imported":
            self._viewport.setText("Rendering preview…")
            self._worker.send("preview.render", {"generation": message.identifier})
        elif message.type == "preview.frame":
            pixmap = QPixmap(str(message.payload["path"]))
            self._viewport.setPixmap(
                pixmap.scaled(
                    self._viewport.size(),
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )
        elif message.type.endswith(".error"):
            self._show_worker_error(
                str(message.payload.get("message", "Blender could not complete that request."))
            )

    def _show_worker_error(self, message: str) -> None:
        QMessageBox.warning(self, "Prism", message)


def main() -> int:
    application = QApplication(sys.argv)
    application.setApplicationName("Prism")
    window = MainWindow()
    window.show()
    return application.exec()


if __name__ == "__main__":
    raise SystemExit(main())
