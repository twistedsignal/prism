"""Versioned JSON Lines protocol shared with the Blender worker."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

PROTOCOL_VERSION = 1


@dataclass(frozen=True)
class Message:
    identifier: int
    type: str
    payload: dict[str, Any]
    version: int = PROTOCOL_VERSION

    def to_line(self) -> bytes:
        return (
            json.dumps(
                {
                    "v": self.version,
                    "id": self.identifier,
                    "type": self.type,
                    "payload": self.payload,
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode()


class ProtocolError(ValueError):
    """Raised when a worker message is invalid or from another protocol version."""


def parse_line(line: bytes) -> Message:
    try:
        raw: object = json.loads(line)
    except json.JSONDecodeError as error:
        raise ProtocolError("Worker sent malformed JSON.") from error
    if not isinstance(raw, dict):
        raise ProtocolError("Worker message must be an object.")
    if raw.get("v") != PROTOCOL_VERSION:
        raise ProtocolError("Worker protocol version is not supported.")
    identifier, message_type, payload = raw.get("id"), raw.get("type"), raw.get("payload")
    if (
        not isinstance(identifier, int)
        or not isinstance(message_type, str)
        or not isinstance(payload, dict)
    ):
        raise ProtocolError("Worker message is missing required fields.")
    return Message(identifier=identifier, type=message_type, payload=payload, version=raw["v"])
