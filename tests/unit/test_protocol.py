import pytest

from prism.renderer.protocol import Message, ProtocolError, parse_line


def test_message_round_trip() -> None:
    message = Message(7, "worker.hello", {"name": "Prism"})
    assert parse_line(message.to_line()) == message


@pytest.mark.parametrize(
    "line", [b"not-json\n", b"[]\n", b'{"v":2,"id":1,"type":"x","payload":{}}\n']
)
def test_parse_rejects_bad_messages(line: bytes) -> None:
    with pytest.raises(ProtocolError):
        parse_line(line)
