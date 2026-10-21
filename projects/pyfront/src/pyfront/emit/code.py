"""The per-scope bytecode buffer: emission, stack accounting, jump patching."""

from __future__ import annotations

from dataclasses import dataclass, field

from ..errors import Unsupported


@dataclass
class Code:
    """Bytecode under construction for one scope, with its stack accounting."""

    buf: bytearray = field(default_factory=bytearray)
    depth: int = 0
    max_depth: int = 0

    def push(self, n: int = 1) -> None:
        self.depth += n
        self.max_depth = max(self.max_depth, self.depth)

    def pop(self, n: int = 1) -> None:
        self.depth -= n

    def op(self, opcode: int, payload: bytes = b"") -> None:
        self.buf.append(opcode)
        self.buf += payload

    def here(self) -> int:
        return len(self.buf)

    def jump(self, opcode: int, trailer: bytes = b"") -> int:
        """Emit a jump with a placeholder; returns the patch site.

        `trailer` is UNWIND_JUMP's extra byte, which follows the offset.
        """
        self.buf.append(opcode)
        site = len(self.buf)
        self.buf += b"\x00\x00" + trailer
        return site

    def ujump(self, opcode: int) -> int:
        """A jump with an *unsigned* relative offset (the *_OR_POP family)."""
        self.buf.append(opcode)
        site = len(self.buf)
        self.buf += b"\x00\x00"
        return site

    def upatch(self, site: int) -> None:
        delta = len(self.buf) - (site + 2)
        if not 0 <= delta < 0x4000:
            raise Unsupported(f"unsigned jump offset {delta} out of range")
        self.buf[site] = 0x80 | (delta & 0x7F)
        self.buf[site + 1] = (delta >> 7) & 0xFF

    def patch_to(self, site: int, target: int) -> None:
        """Point a previously emitted jump at `target`."""
        delta = target - (site + 2)
        n = delta + 0x4000
        if not 0 <= n < 0x8000:
            raise Unsupported(f"jump offset {delta} out of the two-byte range")
        self.buf[site] = 0x80 | (n & 0x7F)
        self.buf[site + 1] = (n >> 7) & 0xFF

    def patch(self, site: int) -> None:
        """Point a previously emitted jump at the current position."""
        delta = len(self.buf) - (site + 2)
        n = delta + 0x4000
        if not 0 <= n < 0x8000:
            raise Unsupported(f"jump offset {delta} out of the two-byte range")
        self.buf[site] = 0x80 | (n & 0x7F)
        self.buf[site + 1] = (n >> 7) & 0xFF
