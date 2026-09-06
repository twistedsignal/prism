"""Asynchronous Qt client for one persistent Blender worker."""

from __future__ import annotations

import itertools
import logging
from enum import StrEnum
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from prism.renderer.protocol import Message, ProtocolError, parse_line

logger = logging.getLogger(__name__)


class WorkerState(StrEnum):
    STOPPED = "stopped"
    STARTING = "starting"
    READY = "ready"
    FAILED = "failed"
    STOPPING = "stopping"


class BlenderWorkerClient(QObject):
    """Owns worker process lifetime. All methods return without waiting for Blender."""

    state_changed = Signal(str)
    message_received = Signal(object)
    user_error = Signal(str)

    def __init__(self, worker_script: Path, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._worker_script = worker_script
        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.ProcessChannelMode.SeparateChannels)
        self._process.readyReadStandardOutput.connect(self._read_stdout)
        self._process.readyReadStandardError.connect(self._read_stderr)
        self._process.errorOccurred.connect(self._on_error)
        self._process.finished.connect(self._on_finished)
        self._next_id = itertools.count(1)
        self._state = WorkerState.STOPPED

    @property
    def state(self) -> WorkerState:
        return self._state

    def start(self, blender_path: Path) -> None:
        if self._state is not WorkerState.STOPPED:
            return
        self._set_state(WorkerState.STARTING)
        environment = QProcessEnvironment.systemEnvironment()
        environment.insert("PYTHONUNBUFFERED", "1")
        self._process.setProcessEnvironment(environment)
        self._process.start(
            str(blender_path), ["--background", "--python", str(self._worker_script)]
        )

    def send(self, message_type: str, payload: dict[str, Any]) -> int | None:
        if self._process.state() is not QProcess.ProcessState.Running:
            self.user_error.emit("Blender is not running.")
            return None
        identifier = next(self._next_id)
        self._process.write(Message(identifier, message_type, payload).to_line())
        return identifier

    def shutdown(self) -> None:
        if self._process.state() is QProcess.ProcessState.NotRunning:
            self._set_state(WorkerState.STOPPED)
            return
        self._set_state(WorkerState.STOPPING)
        self.send("worker.shutdown", {})
        QTimer.singleShot(3_000, self._force_stop_if_needed)

    def _force_stop_if_needed(self) -> None:
        if self._process.state() is not QProcess.ProcessState.NotRunning:
            logger.warning("Blender did not stop within the shutdown timeout; terminating it.")
            self._process.terminate()
            QTimer.singleShot(1_000, self._kill_if_needed)

    def _kill_if_needed(self) -> None:
        if self._process.state() is not QProcess.ProcessState.NotRunning:
            logger.error("Blender did not terminate after the shutdown timeout; killing it.")
            self._process.kill()

    def _read_stdout(self) -> None:
        while self._process.canReadLine():
            line = bytes(self._process.readLine().data())
            try:
                message = parse_line(line)
            except ProtocolError:
                logger.debug(
                    "Ignoring non-protocol Blender stdout: %s",
                    line.decode(errors="replace").rstrip(),
                )
                continue
            if message.type == "worker.ready":
                self._set_state(WorkerState.READY)
            self.message_received.emit(message)

    def _read_stderr(self) -> None:
        data = bytes(self._process.readAllStandardError().data()).decode(errors="replace").rstrip()
        if data:
            logger.info("Blender worker: %s", data)

    def _on_error(self, _error: QProcess.ProcessError) -> None:
        if self._state is not WorkerState.STOPPING:
            self._set_state(WorkerState.FAILED)
            self.user_error.emit("Prism could not start or communicate with Blender.")

    def _on_finished(self, _exit_code: int, _status: QProcess.ExitStatus) -> None:
        if self._state is WorkerState.STOPPING:
            self._set_state(WorkerState.STOPPED)
        else:
            self._set_state(WorkerState.FAILED)
            self.user_error.emit("Blender stopped unexpectedly. Your settings are still available.")

    def _set_state(self, state: WorkerState) -> None:
        if state is self._state:
            return
        self._state = state
        self.state_changed.emit(state.value)
