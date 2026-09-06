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

from prism.core.settings import RenderSettings


class SettingsPanel(QScrollArea):
    camera_changed = Signal(float, float, float, float, float)
    projection_changed = Signal(bool)
    lighting_changed = Signal(float, float, float)
    material_changed = Signal(bool, float, float, float, float, float)
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

    def set_settings(self, settings: RenderSettings) -> None:
        controls = (
            *self._camera_controls,
            self._projection_control,
            *self._lighting_controls,
            *self._material_controls,
            *self._geometry_controls,
            *self._cavity_controls,
            *self._output_controls,
        )
        previous = [control.blockSignals(True) for control in controls]
        yaw, pitch, distance, roll, field_of_view = self._camera_controls
        yaw.setValue(settings.camera.yaw_degrees)
        pitch.setValue(settings.camera.pitch_degrees)
        distance.setValue(settings.camera.distance)
        roll.setValue(settings.camera.roll_degrees)
        field_of_view.setValue(settings.camera.field_of_view_degrees)
        self._projection_control.setChecked(settings.camera.projection.value == "orthographic")
        key, fill, world = self._lighting_controls
        key.setValue(settings.lighting.key_energy)
        fill.setValue(settings.lighting.fill_energy)
        world.setValue(settings.lighting.world_strength)
        original, roughness, metallic, red, green, blue = self._material_controls
        original.setChecked(settings.material.use_original)
        roughness.setValue(settings.material.roughness)
        metallic.setValue(settings.material.metallic)
        red.setValue(settings.material.base_color.red)
        green.setValue(settings.material.base_color.green)
        blue.setValue(settings.material.base_color.blue)
        subdivision, smooth = self._geometry_controls
        subdivision.setValue(settings.geometry.subdivision_level)
        smooth.setChecked(settings.geometry.smooth_shading)
        enabled, ridge, valley = self._cavity_controls
        enabled.setChecked(settings.cavity.enabled)
        ridge.setValue(settings.cavity.ridge_strength)
        valley.setValue(settings.cavity.valley_strength)
        width, height, transparent, engine = self._output_controls
        width.setValue(settings.output.width)
        height.setValue(settings.output.height)
        transparent.setChecked(settings.output.transparent_background)
        engine.setCurrentIndex(0 if settings.output.engine.value == "eevee" else 1)
        for control, was_blocked in zip(controls, previous, strict=True):
            control.blockSignals(was_blocked)

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
        yaw, pitch, distance, roll, field_of_view = (
            self._number(-360, 360, 35),
            self._number(-89, 89, 25),
            self._number(0.01, 1000, 4),
            self._number(-180, 180, 0),
            self._number(1, 179, 50),
        )
        self._camera_controls = (yaw, pitch, distance, roll, field_of_view)
        orthographic = QCheckBox()
        self._projection_control = orthographic
        layout.addRow("Yaw", yaw)
        layout.addRow("Pitch", pitch)
        layout.addRow("Distance", distance)
        layout.addRow("Roll", roll)
        layout.addRow("FOV", field_of_view)
        layout.addRow("Orthographic", orthographic)
        for control in (yaw, pitch, distance, roll, field_of_view):
            control.valueChanged.connect(
                lambda _value: self.camera_changed.emit(
                    yaw.value(),
                    pitch.value(),
                    distance.value(),
                    roll.value(),
                    field_of_view.value(),
                )
            )
        orthographic.toggled.connect(self.projection_changed)
        return group

    def _lighting_group(self) -> QGroupBox:
        group = QGroupBox("Lighting")
        layout = QFormLayout(group)
        key, fill, world = (
            self._number(0, 100000, 1100),
            self._number(0, 100000, 260),
            self._number(0, 10, 1),
        )
        self._lighting_controls = (key, fill, world)
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
        red, green, blue = self._number(0, 1, 0.8), self._number(0, 1, 0.8), self._number(0, 1, 0.8)
        self._material_controls = (original, roughness, metallic, red, green, blue)
        layout.addRow("Use original", original)
        layout.addRow("Roughness", roughness)
        layout.addRow("Metallic", metallic)
        layout.addRow("Red", red)
        layout.addRow("Green", green)
        layout.addRow("Blue", blue)
        original.toggled.connect(
            lambda _value: self.material_changed.emit(
                original.isChecked(),
                roughness.value(),
                metallic.value(),
                red.value(),
                green.value(),
                blue.value(),
            )
        )
        for control in (roughness, metallic, red, green, blue):
            control.valueChanged.connect(
                lambda _value: self.material_changed.emit(
                    original.isChecked(),
                    roughness.value(),
                    metallic.value(),
                    red.value(),
                    green.value(),
                    blue.value(),
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
        self._geometry_controls = (subdivision, smooth)
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
        self._cavity_controls = (enabled, ridge, valley)
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
        self._output_controls = (width, height, transparent, engine)
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
