"""Prism application entry point."""

from __future__ import annotations

import sys

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QLabel, QMainWindow, QSplitter, QVBoxLayout, QWidget


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("Prism")
        self.resize(1280, 800)
        viewport = QLabel("Import a model to begin")
        viewport.setObjectName("viewport")
        viewport.setAlignment(Qt.AlignmentFlag.AlignCenter)
        sidebar = QWidget()
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.addWidget(
            QLabel(
                "Model\n\nCamera\n\nLighting\n\nMaterial\n\nGeometry\n\nDetail / Cavity\n\nOutput"
            )
        )
        sidebar_layout.addStretch(1)
        split = QSplitter()
        split.addWidget(viewport)
        split.addWidget(sidebar)
        split.setSizes([960, 320])
        self.setCentralWidget(split)


def main() -> int:
    application = QApplication(sys.argv)
    application.setApplicationName("Prism")
    window = MainWindow()
    window.show()
    return application.exec()


if __name__ == "__main__":
    raise SystemExit(main())
