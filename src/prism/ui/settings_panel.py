"""Compact settings sidebar for the first complete renderer workflow."""

from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QScrollArea,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)


class SettingsPanel(QScrollArea):
    camera_changed = Signal(float, float, float)
    lighting_changed = Signal(float, float, float)
    material_changed = Signal(bool, float, float)
    geometry_changed = Signal(int, bool)
    cavity_changed = Signal(bool, float, float)
    output_changed = Signal(int, int, bool, str)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWidgetResizable(True)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.addWidget(self._camera_group())
        layout.addWidget(self._lighting_group())
        layout.addWidget(self._material_group())
        layout.addWidget(self._geometry_group())
        layout.addWidget(self._cavity_group())
        layout.addWidget(self._output_group())
        layout.addStretch(1)
        self.setWidget(content)

    def _number(
        self, minimum: float, maximum: float, value: float, decimals: int = 2
    ) -> QDoubleSpinBox:
        control = QDoubleSpinBox()
        control.setRange(minimum, maximum)
        control.setValue(value)
        control.setDecimals(decimals)
        return control

    def _camera_group(self) -> QGroupBox:
        group = QGroupBox("Camera")
        group.setCheckable(True)
        group.setChecked(True)
        layout = QFormLayout(group)
        yaw, pitch, distance = (
            self._number(-360, 360, 35),
            self._number(-89, 89, 25),
            self._number(0.01, 1000, 4),
        )
        layout.addRow("Yaw", yaw)
        layout.addRow("Pitch", pitch)
        layout.addRow("Distance", distance)
        for control in (yaw, pitch, distance):
            control.valueChanged.connect(
                lambda _value: self.camera_changed.emit(
                    yaw.value(), pitch.value(), distance.value()
                )
            )
        return group

    def _lighting_group(self) -> QGroupBox:
        group = QGroupBox("Lighting")
        layout = QFormLayout(group)
        key, fill, world = (
            self._number(0, 100000, 1100),
            self._number(0, 100000, 260),
            self._number(0, 10, 1),
        )
        layout.addRow("Key energy", key)
        layout.addRow("Fill energy", fill)
        layout.addRow("World", world)
        for control in (key, fill, world):
            control.valueChanged.connect(
                lambda _value: self.lighting_changed.emit(key.value(), fill.value(), world.value())
            )
        return group

    def _material_group(self) -> QGroupBox:
        group = QGroupBox("Material")
        layout = QFormLayout(group)
        original = QCheckBox()
        original.setChecked(True)
        roughness, metallic = self._number(0, 1, 0.45), self._number(0, 1, 0)
        layout.addRow("Use original", original)
        layout.addRow("Roughness", roughness)
        layout.addRow("Metallic", metallic)
        original.toggled.connect(
            lambda _value: self.material_changed.emit(
                original.isChecked(), roughness.value(), metallic.value()
            )
        )
        for control in (roughness, metallic):
            control.valueChanged.connect(
                lambda _value: self.material_changed.emit(
                    original.isChecked(), roughness.value(), metallic.value()
                )
            )
        return group

    def _geometry_group(self) -> QGroupBox:
        group = QGroupBox("Geometry")
        layout = QFormLayout(group)
        subdivision = QSpinBox()
        subdivision.setRange(0, 6)
        smooth = QCheckBox()
        smooth.setChecked(True)
        layout.addRow("Subdivision", subdivision)
        layout.addRow("Smooth shading", smooth)
        subdivision.valueChanged.connect(
            lambda _value: self.geometry_changed.emit(subdivision.value(), smooth.isChecked())
        )
        smooth.toggled.connect(
            lambda _value: self.geometry_changed.emit(subdivision.value(), smooth.isChecked())
        )
        return group

    def _cavity_group(self) -> QGroupBox:
        group = QGroupBox("Detail / cavity")
        layout = QFormLayout(group)
        enabled = QCheckBox()
        enabled.setChecked(True)
        ridge, valley = self._number(0, 2, 0.35), self._number(0, 2, 0.65)
        layout.addRow("Enabled", enabled)
        layout.addRow("Ridge", ridge)
        layout.addRow("Valley / AO", valley)
        enabled.toggled.connect(
            lambda _value: self.cavity_changed.emit(
                enabled.isChecked(), ridge.value(), valley.value()
            )
        )
        for control in (ridge, valley):
            control.valueChanged.connect(
                lambda _value: self.cavity_changed.emit(
                    enabled.isChecked(), ridge.value(), valley.value()
                )
            )
        return group

    def _output_group(self) -> QGroupBox:
        group = QGroupBox("Output")
        layout = QFormLayout(group)
        width, height = QSpinBox(), QSpinBox()
        for control in (width, height):
            control.setRange(1, 16384)
            control.setValue(1024)
        transparent = QCheckBox()
        engine = QComboBox()
        engine.addItem("Eevee", "eevee")
        engine.addItem("Cycles", "cycles")
        layout.addRow("Width", width)
        layout.addRow("Height", height)
        layout.addRow("Transparent", transparent)
        layout.addRow("Final engine", engine)
        width.valueChanged.connect(
            lambda _value: self.output_changed.emit(
                width.value(), height.value(), transparent.isChecked(), str(engine.currentData())
            )
        )
        height.valueChanged.connect(
            lambda _value: self.output_changed.emit(
                width.value(), height.value(), transparent.isChecked(), str(engine.currentData())
            )
        )
        transparent.toggled.connect(
            lambda _value: self.output_changed.emit(
                width.value(), height.value(), transparent.isChecked(), str(engine.currentData())
            )
        )
        engine.currentIndexChanged.connect(
            lambda _value: self.output_changed.emit(
                width.value(), height.value(), transparent.isChecked(), str(engine.currentData())
            )
        )
        return group
