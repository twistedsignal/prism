"""Image-backed interactive orbit viewport."""

from __future__ import annotations

from PySide6.QtCore import QPoint, Qt, Signal
from PySide6.QtGui import QKeyEvent, QMouseEvent, QPixmap, QWheelEvent
from PySide6.QtWidgets import QLabel, QWidget

from prism.core.camera import orbit, pan, zoom
from prism.core.settings import CameraSettings


class ViewportWidget(QLabel):
    """Displays Blender frames and computes camera changes locally."""

    camera_changed = Signal(object, bool)
    frame_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__("Starting Blender…", parent)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumSize(640, 480)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setStyleSheet("background: #171923; color: #c7cad8;")
        self._camera = CameraSettings()
        self._frame: QPixmap | None = None
        self._last_position: QPoint | None = None
        self._drag_button = Qt.MouseButton.NoButton

    def set_camera(self, camera: CameraSettings) -> None:
        self._camera = camera

    def set_frame(self, path: str) -> None:
        pixmap = QPixmap(path)
        if pixmap.isNull():
            self.setText("Blender returned an unreadable preview frame.")
            return
        self._frame = pixmap
        self._update_pixmap()

    def resizeEvent(self, event: object) -> None:
        super().resizeEvent(event)  # type: ignore[arg-type]
        self._update_pixmap()

    def mousePressEvent(self, event: QMouseEvent) -> None:
        self._last_position = event.position().toPoint()
        self._drag_button = event.button()
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._last_position is None:
            return
        position = event.position().toPoint()
        delta = position - self._last_position
        self._last_position = position
        if self._drag_button is Qt.MouseButton.LeftButton:
            self._camera = orbit(self._camera, float(delta.x()), float(delta.y()))
        elif self._drag_button is Qt.MouseButton.MiddleButton:
            self._camera = pan(self._camera, float(delta.x()), float(delta.y()))
        else:
            return
        self.camera_changed.emit(self._camera, True)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._last_position = None
        self._drag_button = Qt.MouseButton.NoButton
        self.camera_changed.emit(self._camera, False)
        super().mouseReleaseEvent(event)

    def wheelEvent(self, event: QWheelEvent) -> None:
        self._camera = zoom(self._camera, float(event.angleDelta().y()))
        self.camera_changed.emit(self._camera, False)

    def keyPressEvent(self, event: QKeyEvent) -> None:
        if event.key() == Qt.Key.Key_F:
            self.frame_requested.emit()
            event.accept()
            return
        super().keyPressEvent(event)

    def _update_pixmap(self) -> None:
        if self._frame is not None:
            self.setPixmap(
                self._frame.scaled(
                    self.size(),
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )
