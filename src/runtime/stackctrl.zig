// zigonly Phase 2 — stack control (deprecated stackctrl.h API).
//
// Vendor reference: vendor/micropython_embed/py/stackctrl.c
//
// In our config (port/mpconfigport.h: MICROPY_CONFIG_ROM_LEVEL_MINIMUM),
// MICROPY_STACK_CHECK defaults to 0, so mp_stack_check / mp_stack_set_limit
// are no-ops on real MicroPython too — the header turns them into
// `(void)(limit)` / empty macros. We provide real symbols anyway so that
// stragglers (or future config bumps) link.
//
// mp_stack_set_top writes MP_STATE_THREAD(stack_top), as vendor does: the
// upper bound of the GC's conservative stack scan (memory/gc.zig).

pub export fn mp_stack_set_top(top: ?*anyopaque) void {
    @import("mpstate.zig").threadState().stack_top = @ptrCast(top);
}

// MICROPY_STACK_CHECK == 0 in this build: callers expect a no-op.
// Kept as an exported real function (not a stub) so any straggler call
// site links cleanly instead of panicking.
pub export fn mp_stack_check() void {}

// ── cstack.c ports (was src/runtime/cstack_shim.c) ─────────────
//
// Under nano (MICROPY_STACK_CHECK=0):
//   - mp_cstack_init_with_top expands to `MP_STATE_THREAD(stack_top) = top`
//     (the stack_size param is unused). Inlined into mp_cstack_init_with_sp_here.
//   - mp_cstack_check is supplied as a static-inline no-op by cstack.h.
//   - mp_cstack_usage is a real exported fn called from modmicropython.c.

const mirrors = @import("../mp_mirrors.zig");

pub export fn mp_cstack_init_with_sp_here(stack_size: usize) void {
    _ = stack_size; // STACK_CHECK=0 nano-dead
    var stack_dummy: u8 = undefined;
    mirrors.mp_state_ctx.thread.stack_top = @as([*]u8, @ptrCast(&stack_dummy));
}

pub export fn mp_cstack_usage() usize {
    var stack_dummy: u8 = undefined;
    const top = @intFromPtr(mirrors.mp_state_ctx.thread.stack_top.?);
    return top - @intFromPtr(&stack_dummy);
}
