"""Latest-state-wins preview request scheduler."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from prism.core.settings import RenderSettings


class PreviewQuality(StrEnum):
    INTERACTION = "interaction"
    IDLE = "idle"


@dataclass(frozen=True)
class PreviewRequest:
    generation: int
    settings: RenderSettings
    quality: PreviewQuality


class PreviewScheduler:
    """Runs one render at a time and retains only the newest pending request."""

    def __init__(self, dispatch: Callable[[PreviewRequest], None]) -> None:
        self._dispatch = dispatch
        self._active: PreviewRequest | None = None
        self._pending: PreviewRequest | None = None
        self._generation = 0

    @property
    def active(self) -> PreviewRequest | None:
        return self._active

    def request(self, settings: RenderSettings, quality: PreviewQuality) -> int:
        self._generation += 1
        request = PreviewRequest(self._generation, settings, quality)
        if self._active is None:
            self._active = request
            self._dispatch(request)
        else:
            self._pending = request
        return request.generation

    def complete(self, generation: int) -> bool:
        if self._active is None or generation != self._active.generation:
            return False
        self._active = None
        if self._pending is not None:
            self._active, self._pending = self._pending, None
            self._dispatch(self._active)
        return True

    def cancel_pending(self) -> None:
        self._pending = None
