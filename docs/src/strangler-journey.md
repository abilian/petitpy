# How it was built

_How petitpy's interpreter moved from MicroPython's C to Zig, one subsystem at a time, without breaking, using the "strangler" pattern._

## The oracle

MicroPython ships a corpus of small Python programs with known output. The project started by freezing that output. From then on every build was checked against the frozen bytes, and any drift failed the build. That one byte-exact check kept a rewrite of the whole runtime, in a different language, correct from start to finish, and it let a large mechanical port proceed without a separate design phase.

## The port

Subsystems were replaced one at a time: lexer, parser, compiler, emitter, `.mpy` loader, VM, object model, allocator, GC. Each got a Zig module with the same link surface as the vendor C file. The C file was then dropped from the build and the Zig module linked in its place. If the binary still linked and the corpus still passed, the port stayed.

Two techniques made this possible. Type mirrors (`src/mp_mirrors.zig`) declare Zig `extern struct` copies of the vendor C structs, with layout checks that fail the build on any mismatch, so Zig code reads and writes vendor structs directly. And every function that can raise returns a `PyError!T` error union; at a C boundary the error becomes a zero return plus a pending exception that the caller checks, so C and Zig callers follow the same rule.

## What was hard

Three pieces resisted the module-by-module approach.

- **The `.mpy` loader** reads a binary format, and a small mistake in it corrupts code silently. It was ported field for field against the vendor loader before the C file went away.
- **qstr registration.** MicroPython's build tools find interned strings and module registrations by scanning C files, so each Zig module needed a small "tombstone" C file just to be seen. A script that lifts those markers out of Zig comments into one generated C file removed them ([qstr Generation](internals/qstr-gen.md)). The built-in module table itself still lives in one C file, because the macro that fills it only expands inside C.
- **Exceptions.** MicroPython unwinds exceptions with `setjmp`/`longjmp`. Zig has no `setjmp`, so every raise site became `return error.PyRaise` and every handler became `try` or `catch`. Once the last vendor NLR file was deleted, exceptions propagated with no `setjmp` at all. That decision is what later made the wasm target practical, since wasm has no native `setjmp` either.

## The end state

The core interpreter contains no vendor C. Vendor C still compiles for features that were never ported, such as floats and the `re` module, because reusing well-tuned upstream code costs less than rewriting it. A few project-local C files remain for unrelated reasons; [Architecture](architecture.md#the-residual-c) lists them. Since the port finished, work has moved to features, size and distribution.

## Lessons

- Corpus goldens are binary fixtures. A trailing-newline tool run over them once broke the build's reference output without anyone noticing.
- In Zig, `_ = &func;` forces the compiler to analyze a function's body and `_ = func;` does not. The wrong form produced green builds that contained code nobody had compiled.
- For a batch of similar conversions, do one first and use it as the pattern for the rest.
- Stop early rather than commit a broken tree. Abandoned attempts were still useful, because each one showed exactly where the coupling was.
