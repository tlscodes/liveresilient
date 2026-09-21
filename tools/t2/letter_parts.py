#!/usr/bin/env python3
"""A letter larger than the door's cap, as up to ten letters in a row — the
receiving half, mirroring apps/reference_app/lib/src/letter_parts.dart byte
for byte (the golden tools/t2/goldens/letter_parts_10.bin pins both).

Part wire (29 B header, then the slice):
  [0..1]   'L' 'P'   magic          [2] version = 1        [3] flags = 0
  [4..7]   id, 4 B, same on every part of one letter
  [8]      index (0-based)          [9] total (1..10)
  [10..12] total length of the whole payload, big-endian u24
  [13..28] sha256 of the whole payload, first 16 B
  [29..]   the slice

The cap per letter (4096) is untouched: each part is one ordinary letter.
A receiver keeps the parts of one id until they are all there (or its own
deadline passes); a missing part is "incomplete", never an exception.
"""
from __future__ import annotations

import hashlib
import os
import secrets
import sys
import time
from dataclasses import dataclass

MAGIC = b"LP"
VERSION = 1
HEADER_BYTES = 29
MAX_PARTS = 60  # sixty since 2026-09-22 (the video letter); the photo keeps thirty on its own
PART_MAX_BYTES = 4096


class LetterTooLong(ValueError):
    pass


class LetterDigestMismatch(ValueError):
    pass


def max_total_bytes(part_max_bytes: int = PART_MAX_BYTES) -> int:
    return (part_max_bytes - HEADER_BYTES) * MAX_PARTS


def id_hex(letter_id: int) -> str:
    return "%08x" % letter_id


@dataclass(frozen=True)
class LetterPart:
    id: int
    index: int
    total: int
    total_length: int
    digest16: bytes
    slice: bytes


def split_letter(payload: bytes, part_max_bytes: int = PART_MAX_BYTES,
                 letter_id: int | None = None) -> list[bytes]:
    """The parts of `payload`, or [payload] bare when it fits in one."""
    if len(payload) <= part_max_bytes:
        return [payload]
    slice_max = part_max_bytes - HEADER_BYTES
    total = (len(payload) + slice_max - 1) // slice_max
    if total > MAX_PARTS:
        raise LetterTooLong("%d B, limit %d B" % (len(payload), slice_max * MAX_PARTS))
    lid = secrets.randbits(32) if letter_id is None else letter_id
    digest = hashlib.sha256(payload).digest()[:16]
    parts = []
    for i in range(total):
        chunk = payload[i * slice_max:(i + 1) * slice_max]
        head = (MAGIC + bytes([VERSION, 0]) + lid.to_bytes(4, "big")
                + bytes([i, total]) + len(payload).to_bytes(3, "big") + digest)
        assert len(head) == HEADER_BYTES
        parts.append(head + chunk)
    return parts


def parse_part(data: bytes) -> LetterPart | None:
    """The part in `data`, or None when it is a bare letter or malformed."""
    if len(data) < HEADER_BYTES or data[:2] != MAGIC or data[2] != VERSION:
        return None
    index, total = data[8], data[9]
    if total < 1 or total > MAX_PARTS or index >= total:
        return None
    return LetterPart(
        id=int.from_bytes(data[4:8], "big"),
        index=index,
        total=total,
        total_length=int.from_bytes(data[10:13], "big"),
        digest16=bytes(data[13:29]),
        slice=bytes(data[29:]),
    )


class LetterAssembler:
    """The parts of ONE letter, any order, duplicates ignored."""

    def __init__(self, letter_id: int):
        self.id = letter_id
        self.total: int | None = None
        self.parts: dict[int, LetterPart] = {}

    @property
    def is_complete(self) -> bool:
        return self.total is not None and len(self.parts) == self.total

    @property
    def missing(self) -> list[int]:
        if self.total is None:
            return []
        return [i for i in range(self.total) if i not in self.parts]

    def add(self, part: LetterPart) -> bool:
        if part.id != self.id:
            return False
        if self.total is not None and part.total != self.total:
            return False
        if self.total is None:
            self.total = part.total
        if part.index in self.parts:
            return False
        self.parts[part.index] = part
        return True

    def assemble(self) -> bytes | None:
        """The whole payload once complete, else None; raises
        LetterDigestMismatch when the bytes do not hash to the carried digest."""
        if not self.is_complete:
            return None
        whole = b"".join(self.parts[i].slice for i in range(self.total))
        first = self.parts[0]
        if len(whole) != first.total_length:
            raise LetterDigestMismatch(id_hex(self.id))
        if hashlib.sha256(whole).digest()[:16] != first.digest16:
            raise LetterDigestMismatch(id_hex(self.id))
        return whole


class LetterPartsCollector:
    """Many letters at once, with a deadline per id: the responder hands
    every assembled payload here; parts are grouped, the whole is returned
    once, and a group whose deadline passes is reported incomplete and
    dropped — never raised."""

    def __init__(self, deadline_s: float = 600.0, now=time.monotonic):
        self.deadline_s = deadline_s
        self._now = now
        self._open: dict[int, tuple[LetterAssembler, float]] = {}
        self.failed: list[int] = []
        # Ids already delivered (bounded): a late duplicate of a finished
        # letter must not open a new, forever-incomplete group.
        self._done: list[int] = []

    def observe(self, payload: bytes) -> tuple[int, bytes] | None:
        """Returns (id, whole) when `payload` completes a letter; None when
        it is not a part, or a part of a still-incomplete letter, or a
        duplicate, or a part whose digest fails (logged by the caller via
        `expired`/`failed`)."""
        part = parse_part(payload)
        if part is None or part.id in self._done:
            return None
        asm, _ = self._open.get(part.id, (None, 0.0))
        if asm is None:
            asm = LetterAssembler(part.id)
        self._open[part.id] = (asm, self._now())
        asm.add(part)
        if not asm.is_complete:
            return None
        del self._open[part.id]
        self._done.append(part.id)
        del self._done[:-64]
        try:
            whole = asm.assemble()
        except LetterDigestMismatch:
            self.failed.append(part.id)
            return None
        return (part.id, whole)

    def expired(self) -> list[tuple[int, int, int, list[int]]]:
        """Groups past the deadline, dropped: (id, received, total, missing)."""
        now = self._now()
        out = []
        for lid, (asm, seen) in list(self._open.items()):
            if now - seen > self.deadline_s:
                out.append((lid, len(asm.parts), asm.total or 0, asm.missing))
                del self._open[lid]
        return out

    @property
    def open_ids(self) -> list[int]:
        return list(self._open)


def _main(argv: list[str]) -> int:
    """letter_parts.py golden <out.bin>   write the 10-part golden
       letter_parts.py assemble <dir>     assemble <dir>/*.letter parts -> <dir>/<idhex>.letter"""
    if len(argv) >= 3 and argv[1] == "golden":
        payload = (bytes(range(256)) * 160)[:40000]
        parts = split_letter(payload, letter_id=0x0BADCAFE)
        with open(argv[2], "wb") as fh:
            for p in parts:
                fh.write(len(p).to_bytes(2, "big") + p)
        print("golden: %d parts, %d B payload, sha256 %s" % (
            len(parts), len(payload), hashlib.sha256(payload).hexdigest()[:16]))
        return 0
    if len(argv) >= 3 and argv[1] == "assemble":
        col = LetterPartsCollector()
        done = 0
        for name in sorted(os.listdir(argv[2])):
            if not name.endswith(".letter"):
                continue
            with open(os.path.join(argv[2], name), "rb") as fh:
                res = col.observe(fh.read())
            if res:
                lid, whole = res
                out = os.path.join(argv[2], id_hex(lid) + ".letter")
                with open(out, "wb") as fh:
                    fh.write(whole)
                print("assembled id=%s bytes=%d sha256=%s -> %s" % (
                    id_hex(lid), len(whole), hashlib.sha256(whole).hexdigest(), out))
                done += 1
        for lid in col.open_ids:
            print("incomplete id=%s" % id_hex(lid))
        return 0 if done else 2
    print(_main.__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
