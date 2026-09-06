from prism.core.settings import RenderSettings
from prism.renderer.scheduler import PreviewQuality, PreviewRequest, PreviewScheduler


def test_latest_pending_preview_wins() -> None:
    dispatched: list[PreviewRequest] = []
    scheduler = PreviewScheduler(dispatched.append)
    settings = RenderSettings()
    first = scheduler.request(settings, PreviewQuality.INTERACTION)
    scheduler.request(settings, PreviewQuality.INTERACTION)
    latest = scheduler.request(settings, PreviewQuality.IDLE)

    assert [request.generation for request in dispatched] == [first]
    assert scheduler.complete(first) is True
    assert [request.generation for request in dispatched] == [first, latest]
    assert scheduler.complete(first) is False
