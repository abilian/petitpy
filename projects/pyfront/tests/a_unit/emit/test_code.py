"""The per-scope buffer: stack accounting and jump patching.

The three `raise Unsupported` lines here were the only uncovered statements in
the module. They are the real ceiling on how large a single compiled scope can
be, and nothing else reaches them: doing so through a real program means
emitting 16KB of bytecode in one function.
"""

from __future__ import annotations

import pytest

from pyfront.emit.code import Code
from pyfront.errors import Unsupported

#: Both patch paths encode the offset in two bytes, 7 bits each.
SIGNED_MAX = 0x4000 - 1  # patch/patch_to: -16384..16383
UNSIGNED_MAX = 0x4000 - 1  # upatch: 0..16383

# ── stack accounting ──────────────────────────────────────────────────────
#
# max_depth becomes the code object's n_state. Under-report it and the VM
# writes past the frame it allocated.


def test_max_depth_is_the_high_water_mark_not_the_final_depth() -> None:
    c = Code()
    c.push(3)
    c.pop(3)
    assert c.depth == 0
    assert c.max_depth == 3


def test_max_depth_does_not_shrink() -> None:
    c = Code()
    c.push(5)
    c.pop(4)
    c.push(1)
    assert c.max_depth == 5


# ── jump patching ─────────────────────────────────────────────────────────


def test_patch_points_a_forward_jump_at_the_current_position() -> None:
    c = Code()
    site = c.jump(0x42)
    c.op(0x51)
    c.patch(site)
    # The offset is relative to the end of the offset field, so the one
    # byte emitted after it means a delta of 1.
    assert c.buf[site:site + 2] == bytes([0x80 | ((1 + 0x4000) & 0x7F), (1 + 0x4000) >> 7 & 0xFF])


def test_patch_to_can_aim_backwards() -> None:
    """A loop's back-edge: the target precedes the jump, so the delta is
    negative. This is the case the +0x4000 bias exists for."""
    c = Code()
    top = c.here()
    c.op(0x51)
    site = c.jump(0x42)
    c.patch_to(site, top)
    assert c.buf[site:site + 2] != b"\x00\x00"  # actually patched


def test_jump_leaves_a_two_byte_hole_plus_any_trailer() -> None:
    """UNWIND_JUMP carries an extra byte after the offset; the patch site
    must point at the offset, not past the trailer."""
    c = Code()
    site = c.jump(0x42, trailer=b"\x02")
    assert c.here() == site + 3


# ── the ceiling ───────────────────────────────────────────────────────────


def test_forward_jump_beyond_two_bytes_is_refused() -> None:
    c = Code()
    site = c.jump(0x42)
    c.buf += b"\x00" * (SIGNED_MAX + 1)
    with pytest.raises(Unsupported, match="two-byte range"):
        c.patch(site)


def test_backward_jump_beyond_two_bytes_is_refused() -> None:
    c = Code()
    c.buf += b"\x00" * (SIGNED_MAX + 2)
    site = c.jump(0x42)
    with pytest.raises(Unsupported, match="two-byte range"):
        c.patch_to(site, 0)


def test_unsigned_jump_beyond_range_is_refused() -> None:
    """The *_OR_POP family encodes an unsigned offset, so it has half the
    reach and no negative case at all."""
    c = Code()
    site = c.ujump(0x42)
    c.buf += b"\x00" * (UNSIGNED_MAX + 1)
    with pytest.raises(Unsupported, match="unsigned jump offset"):
        c.upatch(site)


def test_a_jump_at_exactly_the_limit_still_patches() -> None:
    """The boundary is the interesting half of a range check: off by one
    here and the compiler refuses programs it could have compiled."""
    c = Code()
    site = c.ujump(0x42)
    c.buf += b"\x00" * UNSIGNED_MAX
    c.upatch(site)  # must not raise
