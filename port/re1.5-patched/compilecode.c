// Copyright 2014 Paul Sokolovsky.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// petitpy patch (2026-07-20): jump offsets widened to int16 so
// long alternation groups compile without overflow. Every Jmp/
// Split/RSplit instruction is now 3 bytes (opcode + 2-byte signed
// little-endian offset) instead of 2. Save/Class counts stay 1-byte
// (they never need >127 sub-groups or char-pairs). Companion changes
// in recursiveloop.c, dumpcode.c, and re1.5.h (NON_ANCHORED_PREFIX
// grew 5→7).

#include "re1.5.h"

// Matches: DSWdsw
#define MATCH_NAMED_CLASS_CHAR(c) (((c) | 0x20) == 'd' || ((c) | 0x24) == 'w')

#define INSERT_CODE(at, num, pc) \
    ((code ? memmove(code + at + num, code + at, pc - at) : 0), pc += num)
// REL now accounts for the wider jump (opcode+2 bytes = 3).
#define REL(at, to) (to - at - 3)
#define EMIT(at, byte) (code ? (code[at] = byte) : (at))
#define EMIT_CHECKED(at, byte) (_emit_checked(at, code, byte, &err))
#define EMIT_JMP_CHECKED(at, val) (_emit_jmp_checked(at, code, val, &err))
#define PC (prog->bytelen)

// 1-byte checked emit — used for Save index + Class count. Both are
// bounded well below 128 so the int8 range is still fine.
static void _emit_checked(int at, char *code, int val, bool *err) {
    *err |= val != (int8_t)val;
    if (code) {
        code[at] = val;
    }
}

// 2-byte checked emit for jump offsets. Writes little-endian int16.
static void _emit_jmp_checked(int at, char *code, int val, bool *err) {
    *err |= val != (int16_t)val;
    if (code) {
        code[at] = val & 0xff;
        code[at + 1] = (val >> 8) & 0xff;
    }
}

static const char *_compilecode(const char *re, ByteProg *prog, int sizecode)
{
    char *code = sizecode ? NULL : prog->insts;
    bool err = false;
    int start = PC;
    int term = PC;
    int alt_label = 0;

    for (; *re && *re != ')'; re++) {
        switch (*re) {
        case '\\':
            re++;
            if (!*re) return NULL; // Trailing backslash
            if (MATCH_NAMED_CLASS_CHAR(*re)) {
                term = PC;
                EMIT(PC++, NamedClass);
                EMIT(PC++, *re);
                prog->len++;
                break;
            }
            MP_FALLTHROUGH
        default:
            term = PC;
            EMIT(PC++, Char);
            EMIT(PC++, *re);
            prog->len++;
            break;
        case '.':
            term = PC;
            EMIT(PC++, Any);
            prog->len++;
            break;
        case '[': {
            int cnt;
            term = PC;
            re++;
            if (*re == '^') {
                EMIT(PC++, ClassNot);
                re++;
            } else {
                EMIT(PC++, Class);
            }
            PC++; // Skip # of pair byte
            prog->len++;
            for (cnt = 0; *re != ']'; re++, cnt++) {
                char c = *re;
                if (c == '\\') {
                    ++re;
                    c = *re;
                    if (MATCH_NAMED_CLASS_CHAR(c)) {
                        c = RE15_CLASS_NAMED_CLASS_INDICATOR;
                        goto emit_char_pair;
                    }
                }
                if (!c) return NULL;
                if (re[1] == '-' && re[2] != ']') {
                    re += 2;
                }
            emit_char_pair:
                EMIT(PC++, c);
                EMIT(PC++, *re);
            }
            EMIT_CHECKED(term + 1, cnt);
            break;
        }
        case '(': {
            term = PC;
            int sub = 0;
            int capture = re[1] != '?' || re[2] != ':';

            if (capture) {
                sub = ++prog->sub;
                EMIT(PC++, Save);
                EMIT_CHECKED(PC++, 2 * sub);
                prog->len++;
            } else {
                    re += 2;
            }

            re = _compilecode(re + 1, prog, sizecode);
            if (re == NULL || *re != ')') return NULL; // error, or no matching paren

            if (capture) {
                EMIT(PC++, Save);
                EMIT_CHECKED(PC++, 2 * sub + 1);
                prog->len++;
            }

            break;
        }
        case '?':
            if (PC == term) return NULL; // nothing to repeat
            // Insert a jump (3 bytes) at `term`, pushing the existing
            // body forward.
            INSERT_CODE(term, 3, PC);
            if (re[1] == '?') {
                EMIT(term, RSplit);
                re++;
            } else {
                EMIT(term, Split);
            }
            EMIT_JMP_CHECKED(term + 1, REL(term, PC));
            prog->len++;
            term = PC;
            break;
        case '*':
            if (PC == term) return NULL; // nothing to repeat
            INSERT_CODE(term, 3, PC);
            EMIT(PC, Jmp);
            EMIT_JMP_CHECKED(PC + 1, REL(PC, term));
            PC += 3;
            if (re[1] == '?') {
                EMIT(term, RSplit);
                re++;
            } else {
                EMIT(term, Split);
            }
            EMIT_JMP_CHECKED(term + 1, REL(term, PC));
            prog->len += 2;
            term = PC;
            break;
        case '+':
            if (PC == term) return NULL; // nothing to repeat
            if (re[1] == '?') {
                EMIT(PC, Split);
                re++;
            } else {
                EMIT(PC, RSplit);
            }
            EMIT_JMP_CHECKED(PC + 1, REL(PC, term));
            PC += 3;
            prog->len++;
            term = PC;
            break;
        case '|':
            if (alt_label) {
                EMIT_JMP_CHECKED(alt_label, REL(alt_label, PC) + 1);
            }
            // Insert 3 bytes at `start` (Split + 2-byte offset), push
            // existing body forward. Emit trailing Jmp (3 bytes) and
            // reserve alt_label for the offset to be patched later.
            INSERT_CODE(start, 3, PC);
            EMIT(PC++, Jmp);
            alt_label = PC;
            PC += 2; // reserved offset slot
            EMIT(start, Split);
            EMIT_JMP_CHECKED(start + 1, REL(start, PC));
            prog->len += 2;
            term = PC;
            break;
        case '^':
            EMIT(PC++, Bol);
            prog->len++;
            term = PC;
            break;
        case '$':
            EMIT(PC++, Eol);
            prog->len++;
            term = PC;
            break;
        }
    }

    if (alt_label) {
        EMIT_JMP_CHECKED(alt_label, REL(alt_label, PC) + 1);
    }
    return err ? NULL : re;
}

int re1_5_sizecode(const char *re)
{
    ByteProg dummyprog = {
         // Save 0, Save 1, Match; more bytes for "search" (vs "match") prefix code
        .bytelen = 5 + NON_ANCHORED_PREFIX
    };

    if (_compilecode(re, &dummyprog, /*sizecode*/1) == NULL) return -1;

    return dummyprog.bytelen;
}

int re1_5_compilecode(ByteProg *prog, const char *re)
{
    prog->len = 0;
    prog->bytelen = 0;
    prog->sub = 0;

    // Non-anchored ("search") prefix — 7 bytes with the widened jumps:
    //   RSplit +4  (opcode + int16=+4 → skip Any+Jmp on split fail)
    //   Any
    //   Jmp    -7  (opcode + int16=-7 → loop back to RSplit)
    // Anchored ("match") skips this via NON_ANCHORED_PREFIX in re1.5.h.
    prog->insts[prog->bytelen++] = RSplit;
    prog->insts[prog->bytelen++] = 4 & 0xff;
    prog->insts[prog->bytelen++] = 0;
    prog->insts[prog->bytelen++] = Any;
    prog->insts[prog->bytelen++] = Jmp;
    prog->insts[prog->bytelen++] = (-7) & 0xff;
    prog->insts[prog->bytelen++] = 0xff; // sign-extension high byte for -7
    prog->len += 3;

    prog->insts[prog->bytelen++] = Save;
    prog->insts[prog->bytelen++] = 0;
    prog->len++;

    re = _compilecode(re, prog, /*sizecode*/0);
    if (re == NULL || *re) return 1;

    prog->insts[prog->bytelen++] = Save;
    prog->insts[prog->bytelen++] = 1;
    prog->len++;

    prog->insts[prog->bytelen++] = Match;
    prog->len++;

    return 0;
}

#if 0
int main(int argc, char *argv[])
{
    int pc = 0;
    ByteProg *code = re1_5_compilecode(argv[1]);
    re1_5_dumpcode(code);
}
#endif
