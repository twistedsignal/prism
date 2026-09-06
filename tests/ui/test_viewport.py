from multiprocessing import shared_memory

from PySide6.QtCore import QPoint, QPointF, Qt
from PySide6.QtGui import QWheelEvent
from PySide6.QtWidgets import QApplication

from prism.core.settings import CameraSettings, OutputSettings, RenderEngine, RenderSettings
from prism.renderer.shared_memory import take_preview_frame
from prism.ui.settings_panel import SettingsPanel
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


def test_preset_settings_synchronize_controls(qtbot: object) -> None:
    panel = SettingsPanel()
    qtbot.addWidget(panel)
    panel.set_settings(
        RenderSettings(
            camera=CameraSettings(yaw_degrees=111, pitch_degrees=-20, distance=8),
            output=OutputSettings(width=640, height=360, engine=RenderEngine.CYCLES),
        )
    )
    yaw, pitch, distance = panel._camera_controls
    width, height, _transparent, engine = panel._output_controls
    assert (yaw.value(), pitch.value(), distance.value()) == (111, -20, 8)
    assert (width.value(), height.value(), engine.currentData()) == (640, 360, "cycles")


def test_shared_memory_preview_frame_becomes_pixmap(qtbot: object) -> None:
    memory = shared_memory.SharedMemory(create=True, size=16)
    memory.buf[:] = bytes([255, 0, 0, 255] * 4)
    pixmap = take_preview_frame({"name": memory.name, "width": 2, "height": 2, "stride": 8})
    memory.close()
    qtbot.addWidget(ViewportWidget())
    assert (pixmap.width(), pixmap.height()) == (2, 2)
