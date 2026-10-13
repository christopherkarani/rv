"""FrameCodec vectors. Ports the ``FrameCodecTests.swift`` cases and pins the
error order from ``sdk/WIRE.md`` §2.
"""

from __future__ import annotations

import struct

import pytest

from rv import frames
from rv.errors import FrameError


def test_encode_prefixes_big_endian_length():
    body = b'{"ok":true}'
    frame = frames.encode(body)
    assert frame == struct.pack(">I", len(body)) + body
    assert frames.decode(frame) == body


def test_encode_rejects_over_cap():
    with pytest.raises(FrameError) as info:
        frames.encode(b"x" * (frames.MAX_BODY_BYTES + 1))
    assert info.value.kind == "oversized"


def test_encode_at_cap_is_allowed():
    body = b"x" * frames.MAX_BODY_BYTES
    assert frames.decode(frames.encode(body)) == body


def test_decode_short_header_is_truncated():
    with pytest.raises(FrameError) as info:
        frames.decode(b"\x00\x00")
    assert info.value.kind == "truncated"


def test_decode_oversized_declared_length():
    frame = struct.pack(">I", frames.MAX_BODY_BYTES + 1)
    with pytest.raises(FrameError) as info:
        frames.decode(frame)
    assert info.value.kind == "oversized"


def test_decode_short_body_is_truncated():
    frame = struct.pack(">I", 10) + b"12345"
    with pytest.raises(FrameError) as info:
        frames.decode(frame)
    assert info.value.kind == "truncated"


def test_decode_long_frame_is_length_mismatch():
    frame = struct.pack(">I", 2) + b"abc"
    with pytest.raises(FrameError) as info:
        frames.decode(frame)
    assert info.value.kind == "lengthMismatch"


def test_decode_zero_length_is_empty():
    with pytest.raises(FrameError) as info:
        frames.decode(struct.pack(">I", 0))
    assert info.value.kind == "empty"


def test_error_order_truncated_beats_oversized_beats_mismatch_beats_empty():
    # Short header reports truncated even though a full read might oversize.
    with pytest.raises(FrameError) as info:
        frames.body_count(b"\xff")
    assert info.value.kind == "truncated"
    # Declared-over-cap beats a (hypothetical) length mismatch.
    with pytest.raises(FrameError) as info:
        frames.body_count(struct.pack(">I", frames.MAX_BODY_BYTES + 1))
    assert info.value.kind == "oversized"
    # Non-4-byte header reports lengthMismatch (split-decode only)...
    with pytest.raises(FrameError) as info:
        frames.body_count(b"\x00\x00\x00\x01\x00")
    assert info.value.kind == "lengthMismatch"
    # ...and zero length reports empty only after the other checks pass.
    with pytest.raises(FrameError) as info:
        frames.body_count(struct.pack(">I", 0))
    assert info.value.kind == "empty"


def test_split_decode_round_trip_and_mismatch():
    body = b'{"ok":true}'
    header = struct.pack(">I", len(body))
    assert frames.decode_split(header, body) == body
    with pytest.raises(FrameError) as info:
        frames.decode_split(header, body + b"x")
    assert info.value.kind == "lengthMismatch"
    with pytest.raises(FrameError) as info:
        frames.decode_split(header, body[:-1])
    assert info.value.kind == "truncated"
