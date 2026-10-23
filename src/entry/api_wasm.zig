//! JavaScript host functions for the wasm build of the embedding API.
//!
//! JavaScript cannot hand wasm a C function pointer, so a host function
//! defined from JavaScript is registered with `jsHost` as its C function
//! and its JavaScript-side id as userdata; `jsHost` calls back out through
//! the `env.ppy_js_call` import, which looks the id up.

const Interp = opaque {};
const Handle = u32;

extern "env" fn ppy_js_call(id: u32, py: *Interp, argc: usize, argv: [*]const Handle, result: *Handle) c_int;
extern fn ppy_define_function(py: *Interp, module: [*:0]const u8, name: [*:0]const u8, f: *const anyopaque, userdata: ?*anyopaque) c_int;

fn jsHost(py: *Interp, userdata: ?*anyopaque, argc: usize, argv: [*]const Handle, result: *Handle) callconv(.c) c_int {
    return ppy_js_call(@intCast(@intFromPtr(userdata)), py, argc, argv, result);
}

export fn ppy_define_js_function(py: *Interp, module: [*:0]const u8, name: [*:0]const u8, id: u32) c_int {
    return ppy_define_function(py, module, name, &jsHost, @ptrFromInt(id));
}
