"""Length-prefix framing. Ports ``Sources/RVIPC/FrameCodec.swift`` exactly:
4-byte big-endian length + JSON body, 1 MiB cap, ordered errors.
See ``sdk/WIRE.md`` §2.
"""

from __future__ import annotations

import struct

from .errors import FrameError

MAX_BODY_BYTES = 1_048_576
_HEADER = struct.Struct(">I")


def encode(body: bytes) -> bytes:
    """Frame ``body``. Empty bodies encode (decoding them is ``empty``)."""
    if len(body) > MAX_BODY_BYTES:
        raise FrameError(
            f"frame body {len(body)} bytes exceeds {MAX_BODY_BYTES}",
            kind="oversized",
        )
    return _HEADER.pack(len(body)) + body


def body_count(header: bytes) -> int:
    """Validate a 4-byte header, reporting errors in wire order:
    truncated → oversized → lengthMismatch → empty.
    """
    if len(header) < 4:
        raise FrameError("frame header short", kind="truncated")
    (declared,) = _HEADER.unpack(header[:4])
    if declared > MAX_BODY_BYTES:
        raise FrameError(f"frame declares {declared} bytes", kind="oversized")
    if len(header) != 4:
        raise FrameError("frame header is not 4 bytes", kind="lengthMismatch")
    if declared == 0:
        raise FrameError("frame body is empty", kind="empty")
    return declared


def decode(frame: bytes) -> bytes:
    """Decode one complete frame."""
    length = body_count(frame[:4])
    expected = 4 + length
    if len(frame) < expected:
        raise FrameError("frame truncated", kind="truncated")
    if len(frame) != expected:
        raise FrameError("frame length mismatch", kind="lengthMismatch")
    return frame[4:expected]


def decode_split(header: bytes, body: bytes) -> bytes:
    """Decode a split frame (header and body received separately)."""
    expected = body_count(header)
    if len(body) < expected:
        raise FrameError("frame body truncated", kind="truncated")
    if len(body) != expected:
        raise FrameError("frame body length mismatch", kind="lengthMismatch")
    return body
