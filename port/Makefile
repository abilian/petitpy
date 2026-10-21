# Generates the self-contained MicroPython embed C package for nanopython.
#
#   make -C port            -> ../vendor/micropython_embed/
#   make -C port clean
#
# embed.mk adds `-I.` so this directory's mpconfigport.h is the active config.
#
# The genhdr step (qstr table, moduledefs, etc.) runs the preprocessor over
# every source file. We unconditionally define NANOPYTHON_CONFIG_FULL during
# this step so the qstr scanner sees the union of nano- and full-arm
# qstrs/modules — the actual C compile picks the right arm from build.zig's
# CFLAGS at zig-build time. This keeps one vendor/ tree compatible with
# both `make build` (nano) and `make build CONFIG=full`.

MICROPYTHON_TOP = ../sandbox/micropython
PACKAGE_DIR = ../vendor/micropython_embed
CFLAGS += -DNANOPYTHON_CONFIG_FULL=1
# Unicode str is a separate switch (build.zig str-unicode); scan with it on.
CFLAGS += -DNANOPYTHON_STR_UNICODE=1
# ADR-002 F1+F2 — for the qstr/moduledef scanner, set every on-by-default
# feature macro so the union of qstrs is collected. Build-time -D flags
# turn features off via the build.zig override path; the scanner has to
# see the maximum set so the runtime can choose between them.
CFLAGS += -DNANOPYTHON_FEATURE_MATH=1
CFLAGS += -DNANOPYTHON_FEATURE_WARNING=1
CFLAGS += -DNANOPYTHON_FEATURE_COLLECTIONS=1
CFLAGS += -DNANOPYTHON_FEATURE_STRUCT=1
CFLAGS += -DNANOPYTHON_FEATURE_ARRAY=1
CFLAGS += -DNANOPYTHON_FEATURE_ERRNO=1
CFLAGS += -DNANOPYTHON_FEATURE_MICROPYTHON=1
CFLAGS += -DNANOPYTHON_FEATURE_GC_MODULE=1
# ADR-006 J1 — JS interop bridge. The scanner sees this with =1 so the
# `_nanopython_js` module qstrs land in qstrdefs.generated.h. Whether
# the runtime actually includes the module is gated at zig-build time
# by -Dfeature-js.
CFLAGS += -DNANOPYTHON_FEATURE_JS=1
# ADR 010 §A3a slice 2 — re module qstrs (compile, match, search,
# split, sub, group, span, start, end, groups, …) need to land in
# qstrdefs.generated.h. Whether the runtime includes the module is
# gated at zig-build time by -Dfeature-re.
CFLAGS += -DNANOPYTHON_FEATURE_RE=1
# notes/plans/full-unix-profile.md phase 1 — `os` module qstrs. Zig-native;
# no vendor C compiled. The scanner just needs to see MP_QSTR_os / MP_QSTR_sep
# / MP_QSTR_environ etc. via the qstr shadow.
CFLAGS += -DNANOPYTHON_FEATURE_OS=1
# notes/plans/full-unix-profile.md phase 2 — `time` module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_TIME=1
# notes/plans/full-unix-profile.md phase 3 — `socket` module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_SOCKET=1
# notes/plans/full-unix-profile.md phase 4 — `select` module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_SELECT=1
# notes/plans/full-unix-profile.md phase 5 — `signal` module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_SIGNAL=1
# notes/plans/full-unix-profile.md phase 7 — `pwd` + `grp` module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_PWD_GRP=1
# notes/plans/full-unix-profile.md phase 6 — `_subprocess` low-level module qstrs.
CFLAGS += -DNANOPYTHON_FEATURE_SUBPROCESS=1

# `zig_qstr_shadow.c` is auto-generated from src/**/*.zig by
# tools/zig_qstr_shadow.py. The scanner only reads .c/.cpp; the shadow
# materialises MP_QSTR_<name> identifiers declared in `// __qstr_shadow_*__`
# anchor blocks inside .zig sources so the qstr table picks them up.
# (Rule body is after the embed.mk include so `all` stays the default goal.)
ZIG_QSTR_SHADOW := build-embed/zig_qstr_shadow.c
ZIG_SOURCES := $(shell find $(abspath ../src) -name '*.zig')
QSTR_GLOBAL_REQUIREMENTS += $(ZIG_QSTR_SHADOW)
SRC_QSTR += $(ZIG_QSTR_SHADOW)
# ADR 010 §A3a slice 2 — extmod/modre.c isn't part of py/ (which embed.mk
# scans by default); add it to SRC_QSTR so the qstr scanner picks up
# its qstrs + MP_REGISTER_EXTENSIBLE_MODULE marker. The actual compile
# happens via build.zig under -Dfeature-re=true.
SRC_QSTR += $(MICROPYTHON_TOP)/extmod/modre.c

include $(MICROPYTHON_TOP)/ports/embed/embed.mk

$(ZIG_QSTR_SHADOW): $(ZIG_SOURCES) $(abspath ../tools/zig_qstr_shadow.py)
	@mkdir -p $(dir $@)
	$(Q)python3 $(abspath ../tools/zig_qstr_shadow.py) $@ $(ZIG_SOURCES)

# Post-process moduledefs.h to gate optional MODULE_DEF_* on their
# MICROPY_PY_* flag. The makemoduledefs scanner runs with
# NANOPYTHON_CONFIG_FULL=1 (above) so it sees all modules; under the
# nano compile, modules whose source is #if MICROPY_PY_X-gated lose
# their `mp_module_X` symbol and the table reference becomes a link
# error. Wrapping MODULE_DEF_X in `#if MICROPY_PY_X` makes the table
# entry empty under nano while staying live under full.
.PHONY: gate-optional-modules
gate-optional-modules: micropython-embed-package
	$(Q)python3 gate_moduledefs.py $(PACKAGE_DIR)/genhdr/moduledefs.h

# nanopython patch — extend the MicroPython grammar with PEP 448
# `{**d}` dict-unpacking. See grammar-patched/patch_grammar.py.
# notes/plans/full-unix-profile.md finding A.3b.
.PHONY: patch-grammar
patch-grammar: micropython-embed-package
	$(Q)python3 grammar-patched/patch_grammar.py $(PACKAGE_DIR)/py/grammar.h

# ADR 010 §A3a slice 2 — copy modre.c + re1.5/ engine into the embed
# package. embed.mk's extmod step only copies modplatform.h; everything
# else has to be pulled in manually. Done as a separate step so the
# embed.mk include stays untouched.
.PHONY: copy-extmod-extras
copy-extmod-extras: micropython-embed-package
	$(Q)mkdir -p $(PACKAGE_DIR)/extmod $(PACKAGE_DIR)/lib/re1.5
	$(Q)cp $(MICROPYTHON_TOP)/extmod/modre.c $(PACKAGE_DIR)/extmod/
	$(Q)cp $(MICROPYTHON_TOP)/lib/re1.5/*.c $(MICROPYTHON_TOP)/lib/re1.5/*.h \
		$(PACKAGE_DIR)/lib/re1.5/
	# nanopython patch — overlay re1.5 with widened (int16) jump
	# offsets so long alternation groups compile without hitting the
	# original int8 limit. Sources in port/re1.5-patched/.
	# notes/plans/full-unix-profile.md finding A.5.
	$(Q)cp re1.5-patched/*.c re1.5-patched/*.h $(PACKAGE_DIR)/lib/re1.5/

all: gate-optional-modules copy-extmod-extras patch-grammar
