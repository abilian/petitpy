// va_list-using functions moved out of Zig.
//
// Zig 0.16's std.builtin.VaList emits @compileError on aarch64-Linux
// under the LLVM backend ("disabled due to miscompilations",
// std/builtin.zig:1041). Since Homebrew's zig 0.16.0 was built with
// LLVM, `use_llvm=false` doesn't move the check (it's a frontend
// analysis on the compiled-in builtin.zig_backend). The workaround
// is to put every function that touches va_list in C.
//
// This file consolidates:
//   - mp_vprintf  — verbatim from vendor mpprint.c:419 (was mpprint.zig:372,
//                   ~250 LOC of format-specifier walk with @cVaArg).
//   - mp_printf   — verbatim vendor variadic wrapper.
//   - vstr_vprintf / vstr_printf — thin wrappers using vstr_add_strn as
//                   the print_strn callback (were vstr.zig).
//   - mp_obj_new_exception_msg_vlist / _varg — verbatim from vendor
//                   objexcept.c:472 (was objexcept.zig — that Zig port
//                   was itself a translation of the same vendor code).
//
// All bodies are 1:1 with vendor at commit b14d129a1 (pinned in
// Makefile). Under our config MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF
// = 0 and MICROPY_ROM_TEXT_COMPRESSION = 0, so the `#if` branches
// that reference `mp_emergency_exception_buf` / `decompressed` compile
// out identically to the vendor build.
//
// Everything else in mpprint.zig / vstr.zig / objexcept.zig stays in
// Zig; only the va_list surface moves here.

#include <assert.h>
#include <stdarg.h>
#include <string.h>

#include "py/obj.h"
#include "py/objstr.h"
#include "py/runtime.h"
#include "py/misc.h"
#include "py/mpprint.h"

// Zig-side symbols this file references. Declared inline because
// notes/lessons-learned/ffi-and-shims.md §1 warns against pulling
// vendor headers into non-Zig shim files when the shim doesn't own
// the header contract — better to enumerate what we actually use.
extern int mp_print_int(const mp_print_t *print, mp_uint_t x, int sgn,
                        int base, int base_char, unsigned int flags,
                        char fill, int width);
// m_malloc_maybe / m_realloc_maybe / m_free are pulled in via
// py/runtime.h below (macros m_new_obj_maybe, m_new_maybe,
// m_renew_maybe expand to these).

// ── mp_vprintf ────────────────────────────────────────────────────────
//
// Copied verbatim from vendor/micropython_embed/py/mpprint.c:419.
// SUPPORT_L_FORMAT / SUPPORT_LL_FORMAT are per-target gates resolved
// by vendor conditions on MP_INT_MAX vs INT_MAX / LONG_MAX; kept 1:1
// with vendor so the resolution matches whatever mpconfigport.h + the
// target ABI produce.

int mp_vprintf(const mp_print_t *print, const char *fmt, va_list args) {
    int chrs = 0;
    for (;;) {
        {
            const char *f = fmt;
            while (*f != '\0' && *f != '%') {
                ++f;
            }
            if (f > fmt) {
                print->print_strn(print->data, fmt, f - fmt);
                chrs += f - fmt;
                fmt = f;
            }
        }

        if (*fmt == '\0') {
            break;
        }

        ++fmt;

        int flags = 0;
        char fill = ' ';
        while (*fmt != '\0') {
            if (*fmt == '-') {
                flags |= PF_FLAG_LEFT_ADJUST;
            } else if (*fmt == '+') {
                flags |= PF_FLAG_SHOW_SIGN;
            } else if (*fmt == ' ') {
                flags |= PF_FLAG_SPACE_SIGN;
            } else if (*fmt == '0') {
                flags |= PF_FLAG_PAD_AFTER_SIGN;
                fill = '0';
            } else {
                break;
            }
            ++fmt;
        }

        int width = 0;
        for (; '0' <= *fmt && *fmt <= '9'; ++fmt) {
            width = width * 10 + *fmt - '0';
        }

        int prec = -1;
        if (*fmt == '.') {
            ++fmt;
            if (*fmt == '*') {
                ++fmt;
                prec = va_arg(args, int);
            } else {
                prec = 0;
                for (; '0' <= *fmt && *fmt <= '9'; ++fmt) {
                    prec = prec * 10 + *fmt - '0';
                }
            }
            if (prec < 0) {
                prec = 0;
            }
        }

        #if (MP_INT_MAX > INT_MAX && MP_INT_MAX == LONG_MAX) || defined(MICROPY_UNIX_COVERAGE)
        #define SUPPORT_L_FORMAT (1)
        #else
        #define SUPPORT_L_FORMAT (0)
        #endif
        #if SUPPORT_L_FORMAT
        bool long_arg = false;
        #endif

        #if (MP_INT_MAX > LONG_MAX) || defined(MICROPY_UNIX_COVERAGE)
        #define SUPPORT_LL_FORMAT (1)
        #else
        #define SUPPORT_LL_FORMAT (0)
        #endif
        #if SUPPORT_LL_FORMAT
        bool long_long_arg = false;
        #endif

        if (*fmt == 'l') {
            ++fmt;
            #if SUPPORT_L_FORMAT
            long_arg = true;
            #endif
            #if SUPPORT_LL_FORMAT
            if (*fmt == 'l') {
                ++fmt;
                long_long_arg = true;
            }
            #endif
        }

        if (*fmt == '\0') {
            break;
        }

        switch (*fmt) {
            case 'b':
                if (va_arg(args, int)) {
                    chrs += mp_print_strn(print, "true", 4, flags, fill, width);
                } else {
                    chrs += mp_print_strn(print, "false", 5, flags, fill, width);
                }
                break;
            case 'c': {
                char str = va_arg(args, int);
                chrs += mp_print_strn(print, &str, 1, flags, fill, width);
                break;
            }
            case 'q': {
                qstr qst = va_arg(args, qstr);
                size_t len;
                const char *str = (const char *)qstr_data(qst, &len);
                if (prec >= 0 && (size_t)prec < len) {
                    len = prec;
                }
                chrs += mp_print_strn(print, str, len, flags, fill, width);
                break;
            }
            case 's': {
                const char *str = va_arg(args, const char *);
                #ifndef NDEBUG
                if (prec != 0 && str == NULL) {
                    chrs += mp_print_strn(print, "(null)", 6, flags, fill, width);
                    break;
                }
                #endif
                size_t len = strlen(str);
                if (prec >= 0 && (size_t)prec < len) {
                    len = prec;
                }
                chrs += mp_print_strn(print, str, len, flags, fill, width);
                break;
            }
            case 'd':
            case 'p':
            case 'P':
            case 'u':
            case 'x':
            case 'X': {
                char fmt_chr = *fmt;
                mp_uint_t val;
                if (fmt_chr == 'p' || fmt_chr == 'P') {
                    val = va_arg(args, uintptr_t);
                }
                #if SUPPORT_LL_FORMAT
                else if (long_long_arg) {
                    val = va_arg(args, unsigned long long);
                }
                #endif
                #if SUPPORT_L_FORMAT
                else if (long_arg) {
                    if (sizeof(long) != sizeof(mp_uint_t) && fmt_chr == 'd') {
                        val = va_arg(args, long);
                    } else {
                        val = va_arg(args, unsigned long);
                    }
                }
                #endif
                else {
                    if (sizeof(int) != sizeof(mp_uint_t) && fmt_chr == 'd') {
                        val = va_arg(args, int);
                    } else {
                        val = va_arg(args, unsigned);
                    }
                }
                int base;
                char fmt_c = (fmt_chr & 0xf0) - 'P' + 'A';
                if (fmt_chr == 'd' || fmt_chr == 'u') {
                    base = 10;
                } else {
                    base = 16;
                }
                chrs += mp_print_int(print, val, fmt_chr == 'd', base, fmt_c, flags, fill, width);
                break;
            }
            #if MICROPY_PY_BUILTINS_FLOAT
            case 'e':
            case 'E':
            case 'f':
            case 'F':
            case 'g':
            case 'G': {
                mp_float_t f = (mp_float_t)va_arg(args, double);
                chrs += mp_print_float(print, f, *fmt, flags, fill, width, prec);
                break;
            }
            #endif
            default:
                assert(*fmt == '%' || !"unsupported fmt char");
                print->print_strn(print->data, fmt, 1);
                chrs += 1;
                break;
        }
        ++fmt;
    }
    return chrs;
}

// ── mp_printf (thin variadic wrapper) ─────────────────────────────────

int mp_printf(const mp_print_t *print, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = mp_vprintf(print, fmt, ap);
    va_end(ap);
    return ret;
}

// ── vstr_vprintf / vstr_printf ────────────────────────────────────────
//
// Thin wrappers: vstr_add_strn is the print_strn callback.

extern void vstr_add_strn(vstr_t *vstr, const char *str, size_t len);

void vstr_vprintf(vstr_t *vstr, const char *fmt, va_list ap) {
    mp_print_t print = {
        .data = vstr,
        .print_strn = (mp_print_strn_t)vstr_add_strn,
    };
    mp_vprintf(&print, fmt, ap);
}

void vstr_printf(vstr_t *vstr, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vstr_vprintf(vstr, fmt, ap);
    va_end(ap);
}

// ── mp_obj_new_exception_msg_vlist / _varg ────────────────────────────
//
// COPIED VERBATIM from vendor/micropython_embed/py/objexcept.c:451-518
// (struct _exc_printer_t, exc_add_strn, mp_obj_new_exception_msg_vlist,
// mp_obj_new_exception_msg_varg). Under our config:
//   MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF = 0 → the `used_emg_buf`
//     branch compiles out (as it does in vendor with the same flag).
//   MICROPY_ROM_TEXT_COMPRESSION = 0 → the `decompressed` branch
//     compiles out identically.
// Preserving vendor's algorithm (single up-front m_new_maybe of the
// buffer, m_renew_maybe growth via allow_realloc, direct mp_obj_str_t
// construction, ROM-alias fallback when buffer alloc fails) instead of
// substituting our own grow-buffer strategy. See CLAUDE.md invariants
// and notes/lessons-learned/strangler-mechanics.md — reverse-strangler
// relocations must be verbatim.

extern const mp_obj_type_t mp_type_str;

struct _exc_printer_t {
    bool allow_realloc;
    size_t alloc;
    size_t len;
    byte *buf;
};

static void exc_add_strn(void *data, const char *str, size_t len) {
    struct _exc_printer_t *pr = data;
    if (pr->len + len >= pr->alloc) {
        // Not enough room for data plus a null byte so try to grow the buffer
        if (pr->allow_realloc) {
            size_t new_alloc = pr->alloc + len + 16;
            byte *new_buf = m_renew_maybe(byte, pr->buf, pr->alloc, new_alloc, true);
            if (new_buf == NULL) {
                pr->allow_realloc = false;
                len = pr->alloc - pr->len - 1;
            } else {
                pr->alloc = new_alloc;
                pr->buf = new_buf;
            }
        } else {
            len = pr->alloc - pr->len - 1;
        }
    }
    memcpy(pr->buf + pr->len, str, len);
    pr->len += len;
}

mp_obj_t mp_obj_new_exception_msg_vlist(const mp_obj_type_t *exc_type, mp_rom_error_text_t fmt, va_list args) {
    assert(fmt != NULL);

    // Check that the given type is an exception type
    assert(MP_OBJ_TYPE_GET_SLOT_OR_NULL(exc_type, make_new) == mp_obj_exception_make_new);

    // Try to allocate memory for the message
    mp_obj_str_t *o_str = m_new_obj_maybe(mp_obj_str_t);
    size_t o_str_alloc = strlen((const char *)fmt) + 1;
    byte *o_str_buf = m_new_maybe(byte, o_str_alloc);

    bool used_emg_buf = false;
    #if MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF
    // If memory allocation failed and there is an emergency buffer then try to use
    // that buffer to store the string object and its data (at least 16 bytes for
    // the string data), reserving room at the start for the traceback and 1-tuple.
    if ((o_str == NULL || o_str_buf == NULL)
        && mp_emergency_exception_buf_size >= (mp_int_t)(EMG_BUF_STR_OFFSET + sizeof(mp_obj_str_t) + 16)) {
        used_emg_buf = true;
        o_str = (mp_obj_str_t *)((uint8_t *)MP_STATE_VM(mp_emergency_exception_buf) + EMG_BUF_STR_OFFSET);
        o_str_buf = (byte *)((uint8_t *)MP_STATE_VM(mp_emergency_exception_buf) + EMG_BUF_STR_BUF_OFFSET);
        o_str_alloc = (uint8_t *)MP_STATE_VM(mp_emergency_exception_buf) + mp_emergency_exception_buf_size - o_str_buf;
    }
    #endif

    if (o_str == NULL) {
        // No memory for the string object so create the exception with no args.
        // The exception will only have a type and no message (compression is irrelevant).
        return mp_obj_exception_make_new(exc_type, 0, 0, NULL);
    }

    if (o_str_buf == NULL) {
        // No memory for the string buffer: assume that the fmt string is in ROM
        // and use that data as the data of the string.
        o_str->len = o_str_alloc - 1; // will be equal to strlen(fmt)
        o_str->data = (const byte *)fmt;
    } else {
        // We have some memory to format the string.
        struct _exc_printer_t exc_pr = {!used_emg_buf, o_str_alloc, 0, o_str_buf};
        mp_print_t print = {&exc_pr, exc_add_strn};
        const char *fmt2 = (const char *)fmt;
        #if MICROPY_ROM_TEXT_COMPRESSION
        byte decompressed[MP_MAX_UNCOMPRESSED_TEXT_LEN];
        if (MP_IS_COMPRESSED_ROM_STRING(fmt)) {
            mp_decompress_rom_string(decompressed, fmt);
            fmt2 = (const char *)decompressed;
        }
        #endif
        mp_vprintf(&print, fmt2, args);
        exc_pr.buf[exc_pr.len] = '\0';
        o_str->len = exc_pr.len;
        o_str->data = exc_pr.buf;
    }

    // Create the string object and call mp_obj_exception_make_new to create the exception
    o_str->base.type = &mp_type_str;
    #if MICROPY_ROM_TEXT_COMPRESSION
    o_str->hash = 0; // will be computed only if string object is accessed
    #else
    o_str->hash = qstr_compute_hash(o_str->data, o_str->len);
    #endif
    mp_obj_t arg = MP_OBJ_FROM_PTR(o_str);
    return mp_obj_exception_make_new(exc_type, 1, 0, &arg);
}

mp_obj_t mp_obj_new_exception_msg_varg(const mp_obj_type_t *exc_type, mp_rom_error_text_t fmt, ...) {
    va_list args;
    va_start(args, fmt);
    mp_obj_t exc = mp_obj_new_exception_msg_vlist(exc_type, fmt, args);
    va_end(args);
    return exc;
}
