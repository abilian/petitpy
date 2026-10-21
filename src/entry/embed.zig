// zigonly Phase 2 — mp_embed_init / mp_embed_deinit.
//
// Direct port of vendor/micropython_embed/port/embed_util.c:37-85. Just a
// 3-line wrapper around mp_stack_set_top + gc_init + mp_init (and mp_deinit
// for the down-path). All three callees are themselves Zig (stackctrl, gc)
// or stub (mp_init), so this commit advances the smoke-test panic from
// "mp_embed_init" → "mp_init" — one rung up the bootstrap ladder.

extern fn mp_stack_set_top(top: ?*anyopaque) void;
extern fn gc_init(start: ?*anyopaque, end: ?*anyopaque) void;
extern fn mp_init() void;
extern fn mp_deinit() void;
extern fn npy_init_full_stubs() void;

pub export fn mp_embed_init(gc_heap: ?*anyopaque, gc_heap_size: usize, stack_top: ?*anyopaque) void {
    mp_stack_set_top(stack_top);
    if (gc_heap) |p| {
        const base: [*]u8 = @ptrCast(p);
        gc_init(@ptrCast(base), @ptrCast(base + gc_heap_size));
    } else {
        gc_init(null, null);
    }
    npy_init_full_stubs();
    mp_init();
}

pub export fn mp_embed_deinit() void {
    mp_deinit();
}
