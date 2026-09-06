from PySide6.QtCore import QPoint, QPointF, Qt
from PySide6.QtGui import QWheelEvent
from PySide6.QtWidgets import QApplication

from prism.ui.viewport import ViewportWidget


def test_left_drag_emits_interaction_camera_update(qtbot: object) -> None:
    viewport = ViewportWidget()
    qtbot.addWidget(viewport)
    viewport.show()
    with qtbot.waitSignal(viewport.camera_changed) as signal:
        qtbot.mousePress(viewport, Qt.MouseButton.LeftButton, pos=QPoint(50, 50))
        qtbot.mouseMove(viewport, QPoint(80, 65))
    camera, interacting = signal.args
    assert interacting is True
    assert camera.yaw_degrees != 35.0


def test_wheel_emits_camera_update(qtbot: object) -> None:
    viewport = ViewportWidget()
    qtbot.addWidget(viewport)
    viewport.show()
    with qtbot.waitSignal(viewport.camera_changed) as signal:
        event = QWheelEvent(
            QPointF(50, 50),
            QPointF(50, 50),
            QPoint(0, 0),
            QPoint(0, 120),
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier,
            Qt.ScrollPhase.NoScrollPhase,
            False,
        )
        QApplication.sendEvent(viewport, event)
    _camera, interacting = signal.args
    assert interacting is False
