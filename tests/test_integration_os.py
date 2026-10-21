"""Integration cases for the Zig-native `os` module.

The whole set gates on `try: import os` so every case is
profile-agnostic — under nano's frozen 541/541 (where `os` is absent)
the ImportError branch prints the same "expected" line.

Cases: 34. See notes/plans/full-unix-profile.md for the module scope.
"""

from __future__ import annotations

# (name, source, expected_stdout) — 3-tuple checks stdout only.
CASES = [
    # Float literals parse correctly rounded on native (libc strtod);
    # vendor's mantissa * 10^exp was an ulp off here. wasm keeps vendor's
    # parser for size (src/frontend/parsenum.zig exactDecimal).
    (
        "float_literal_parses_correctly_rounded",
        (
            "try:\n"
            "    import os\n"
            "    print(2.2250738585072014e-308, float('1_000.000_000_000_000_1'), 0.1e-308 * 1e308)\n"
            "except ImportError:\n"
            "    print('2.2250738585072014e-308 1000.0000000000001 0.10000000000000019')\n"
        ),
        "2.2250738585072014e-308 1000.0000000000001 0.10000000000000019\n",
    ),
    # ── finalisers (ADR 019) ────────────────────────────────────────
    # Files and sockets dropped without close() are closed by the
    # collector through their `__del__`; before finalisers each one
    # leaked a descriptor until exit.
    (
        "gc_closes_dropped_files_and_sockets",
        (
            "try:\n"
            "    import gc, os, socket\n"
            "    path = '/tmp/nanopy_int_fin_' + str(os.getpid())\n"
            "    before = len(os.listdir('/dev/fd'))\n"
            "    for i in range(200):\n"
            "        f = open(path, 'w')\n"
            "        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    f = s = None\n"
            "    gc.collect()\n"
            "    leaked = len(os.listdir('/dev/fd')) - before\n"
            "    os.remove(path)\n"
            "    print(leaked < 10)\n"
            "except ImportError:\n"
            "    print(True)\n"
        ),
        "True\n",
    ),
    # ── urandom ─────────────────────────────────────────────────────
    (
        "os_urandom_len",
        (
            "try:\n"
            "    import os\n"
            "    print(len(os.urandom(16)), len(os.urandom(0)), len(os.urandom(1)))\n"
            "except ImportError:\n"
            "    print('16 0 1')\n"
        ),
        "16 0 1\n",
    ),
    (
        "os_urandom_bytes_type",
        (
            "try:\n"
            "    import os\n"
            "    print(isinstance(os.urandom(4), bytes))\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "os_urandom_neg_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.urandom(-1)\n"
            "    except OSError:\n"
            "        print('ok')\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    (
        "os_urandom_efbig",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.urandom(10000)  # > 4096 → EFBIG (27)\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 27)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── open/read/write/close/fsync ─────────────────────────────────
    (
        "os_open_write_read_close",
        (
            "try:\n"
            "    import os\n"
            "    pid = os.getpid()\n"
            "    path = '/tmp/nanopy_int_' + str(pid)\n"
            "    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    n = os.write(fd, b'abc')\n"
            "    os.fsync(fd); os.close(fd)\n"
            "    fd = os.open(path, os.O_RDONLY)\n"
            "    d = os.read(fd, 16); os.close(fd)\n"
            "    print(n, d)\n"
            "except ImportError:\n"
            "    print('3 b\\'abc\\'')\n"
        ),
        "3 b'abc'\n",
    ),
    (
        "os_open_enoent_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.open('/nonexistent/nope', os.O_RDONLY)\n"
            "    except OSError as e:\n"
            "        print('OSError', e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('OSError True')\n"
        ),
        "OSError True\n",
    ),
    (
        "os_fsync_valid_fd",
        (
            "try:\n"
            "    import os\n"
            "    p = '/tmp/nanopy_fsync_' + str(os.getpid())\n"
            "    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.write(fd, b'x')\n"
            "    os.fsync(fd)  # returns None on success\n"
            "    os.close(fd)\n"
            "    os.remove(p)\n"
            "    print('ok')\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    (
        "os_fsync_bad_fd_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.fsync(999999)\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 9)  # EBADF\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── process (getpid, kill) ──────────────────────────────────────
    (
        "os_kill_esrch_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.kill(-99999, 0)\n"
            "    except OSError:\n"
            "        print('ok')\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    # ── int constants ───────────────────────────────────────────────
    (
        "os_o_flag_constants_are_int",
        (
            "try:\n"
            "    import os\n"
            "    print(all(isinstance(x, int) for x in ("
            "os.O_RDONLY, os.O_WRONLY, os.O_RDWR, os.O_CREAT, os.O_TRUNC, os.O_APPEND, os.O_EXCL)))\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── cwd / env ──────────────────────────────────────────────────
    (
        "os_getcwd_type",
        (
            "try:\n"
            "    import os\n"
            "    print(isinstance(os.getcwd(), str), os.getcwd().startswith('/'))\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "os_getenv_default",
        (
            "try:\n"
            "    import os\n"
            "    print(os.getenv('NANOPY_DEFINITELY_NOT_SET') is None,\n"
            "          os.getenv('NANOPY_DEFINITELY_NOT_SET', 'x') == 'x')\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "os_putenv_getenv_roundtrip",
        (
            "try:\n"
            "    import os\n"
            "    os.putenv('NANOPY_RT', 'hello')\n"
            "    print(os.getenv('NANOPY_RT'))\n"
            "    os.unsetenv('NANOPY_RT')\n"
            "    print(os.getenv('NANOPY_RT'))\n"
            "except ImportError:\n"
            "    print('hello\\nNone')\n"
        ),
        "hello\nNone\n",
    ),
    (
        "os_chdir_roundtrip",
        (
            "try:\n"
            "    import os\n"
            "    here = os.getcwd()\n"
            "    os.chdir('/tmp')\n"
            "    at_tmp = os.getcwd()\n"
            "    os.chdir(here)\n"
            "    # macOS's /tmp is a symlink to /private/tmp, hence the endswith check\n"
            "    print(at_tmp.endswith('/tmp'), os.getcwd() == here)\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "os_chdir_missing_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.chdir('/nonexistent/nope')\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── file-system verbs (mkdir, rename, rmdir, remove) ────────────
    (
        "os_mkdir_rename_rmdir",
        (
            "try:\n"
            "    import os\n"
            "    base = '/tmp/nanopy_it_' + str(os.getpid())\n"
            "    os.mkdir(base, 0o755)\n"
            "    os.rename(base, base + '_r')\n"
            "    os.rmdir(base + '_r')\n"
            "    print('ok')\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    (
        "os_remove_missing_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.remove('/tmp/nanopy_missing_' + str(os.getpid()))\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── string constants ────────────────────────────────────────────
    (
        "os_string_constants",
        (
            "try:\n"
            "    import os\n"
            "    print(os.sep, os.curdir, os.pardir, os.name)\n"
            "except ImportError:\n"
            "    print('/ . .. posix')\n"
        ),
        "/ . .. posix\n",
    ),
    (
        "os_string_equality",
        (
            "try:\n"
            "    import os\n"
            "    print(os.sep == '/', os.name == 'posix', os.linesep == '\\n')\n"
            "except ImportError:\n"
            "    print('True True True')\n"
        ),
        "True True True\n",
    ),
    (
        "os_sep_join",
        (
            "try:\n"
            "    import os\n"
            "    print(os.sep.join(['a', 'b', 'c']))\n"
            "except ImportError:\n"
            "    print('a/b/c')\n"
        ),
        "a/b/c\n",
    ),
    # ── stat/lstat/listdir ──────────────────────────────────────────
    (
        "os_stat_basic",
        (
            "try:\n"
            "    import os\n"
            "    st = os.stat('/etc/hosts')\n"
            "    print(isinstance(st.st_mode, int), st.st_size >= 0, len(st) == 10)\n"
            "    print(st[0] == st.st_mode, st[6] == st.st_size)\n"
            "    # S_IFREG = 0o100000 — /etc/hosts is a regular file everywhere\n"
            "    print((st.st_mode & 0o170000) == 0o100000)\n"
            "except ImportError:\n"
            "    print('True True True'); print('True True'); print('True')\n"
        ),
        "True True True\nTrue True\nTrue\n",
    ),
    (
        "os_stat_missing_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.stat('/nonexistent/nope/nada')\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "os_stat_dir_vs_file",
        (
            "try:\n"
            "    import os\n"
            "    dir_mode = os.stat('/etc').st_mode & 0o170000\n"
            "    file_mode = os.stat('/etc/hosts').st_mode & 0o170000\n"
            "    print(dir_mode == 0o040000, file_mode == 0o100000)\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "os_listdir_basic",
        (
            "try:\n"
            "    import os\n"
            "    entries = os.listdir('/etc')\n"
            "    print(isinstance(entries, list), 'hosts' in entries)\n"
            "    print('.' not in entries, '..' not in entries)\n"
            "except ImportError:\n"
            "    print('True True'); print('True True')\n"
        ),
        "True True\nTrue True\n",
    ),
    (
        "os_listdir_missing_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.listdir('/nonexistent/nope')\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── access ──────────────────────────────────────────────────────
    (
        "os_access_bool",
        (
            "try:\n"
            "    import os\n"
            "    print(os.access('/etc/hosts', os.F_OK), os.access('/nonexistent/nope', os.F_OK))\n"
            "except ImportError:\n"
            "    print('True False')\n"
        ),
        "True False\n",
    ),
    (
        "os_access_constants",
        (
            "try:\n"
            "    import os\n"
            "    print(os.F_OK, os.R_OK, os.W_OK, os.X_OK)\n"
            "except ImportError:\n"
            "    print('0 4 2 1')\n"
        ),
        "0 4 2 1\n",
    ),
    # ── chmod, chown ────────────────────────────────────────────────
    (
        "os_chmod_roundtrip",
        (
            "try:\n"
            "    import os\n"
            "    p = '/tmp/nanopy_chmod_' + str(os.getpid())\n"
            "    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.close(fd)\n"
            "    os.chmod(p, 0o644)\n"
            "    m = os.stat(p).st_mode & 0o777\n"
            "    print(m == 0o644)\n"
            "    os.remove(p)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "os_chmod_missing_raises",
        (
            "try:\n"
            "    import os\n"
            "    try:\n"
            "        os.chmod('/nonexistent/nope', 0o644)\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 2)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # chown to same uid/gid we already are — always allowed, doesn't
    # require root. This exercises the syscall path without needing
    # extra privileges in CI.
    (
        "os_chown_self_noop",
        (
            "try:\n"
            "    import os\n"
            "    p = '/tmp/nanopy_chown_' + str(os.getpid())\n"
            "    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.close(fd)\n"
            "    st = os.stat(p)\n"
            "    os.chown(p, st.st_uid, st.st_gid)  # same → no-op\n"
            "    print('ok')\n"
            "    os.remove(p)\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    # ── symlink / readlink ──────────────────────────────────────────
    (
        "os_symlink_readlink_lstat",
        (
            "try:\n"
            "    import os\n"
            "    pid = os.getpid()\n"
            "    tgt = '/tmp/nanopy_st_tgt_' + str(pid)\n"
            "    lnk = '/tmp/nanopy_st_lnk_' + str(pid)\n"
            "    fd = os.open(tgt, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.close(fd)\n"
            "    os.symlink(tgt, lnk)\n"
            "    print(os.readlink(lnk) == tgt)\n"
            "    print((os.lstat(lnk).st_mode & 0o170000) == 0o120000)  # S_IFLNK\n"
            "    print((os.stat(lnk).st_mode & 0o170000) == 0o100000)   # S_IFREG (follows)\n"
            "    os.unlink(lnk); os.remove(tgt)\n"
            "except ImportError:\n"
            "    print('True'); print('True'); print('True')\n"
        ),
        "True\nTrue\nTrue\n",
    ),
    (
        "os_symlink_eexist_raises",
        (
            "try:\n"
            "    import os\n"
            "    pid = os.getpid()\n"
            "    tgt = '/tmp/nanopy_se_tgt_' + str(pid)\n"
            "    lnk = '/tmp/nanopy_se_lnk_' + str(pid)\n"
            "    fd = os.open(tgt, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.close(fd)\n"
            "    os.symlink(tgt, lnk)\n"
            "    try:\n"
            "        os.symlink(tgt, lnk)\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 17)  # EEXIST\n"
            "    os.unlink(lnk); os.remove(tgt)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "os_readlink_not_a_link_raises",
        (
            "try:\n"
            "    import os\n"
            "    pid = os.getpid()\n"
            "    p = '/tmp/nanopy_rl_reg_' + str(pid)\n"
            "    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)\n"
            "    os.close(fd)\n"
            "    try:\n"
            "        os.readlink(p)  # regular file → EINVAL\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 22)  # EINVAL\n"
            "    os.remove(p)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── time (phase 2 of the full-unix plan) ────────────────────────
    # `time` is a separate module but shares the smoke-test shape with
    # os — same profile gate, same ImportError short-circuit under nano.
    (
        "time_time_is_float",
        (
            "try:\n"
            "    import time\n"
            "    t = time.time()\n"
            "    print(isinstance(t, float), t > 1600000000)\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "time_monotonic_advances",
        (
            "try:\n"
            "    import time\n"
            "    a = time.monotonic()\n"
            "    time.sleep(0.005)\n"
            "    b = time.monotonic()\n"
            "    print(b > a)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "time_ns_variants_are_int",
        (
            "try:\n"
            "    import time\n"
            "    print(isinstance(time.time_ns(), int), isinstance(time.monotonic_ns(), int))\n"
            "except ImportError:\n"
            "    print('True True')\n"
        ),
        "True True\n",
    ),
    (
        "time_sleep_negative_raises",
        (
            "try:\n"
            "    import time\n"
            "    try:\n"
            "        time.sleep(-1)\n"
            "    except OSError as e:\n"
            "        print(e.args[0] == 22)  # EINVAL\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "time_perf_counter_aliases_monotonic",
        (
            "try:\n"
            "    import time\n"
            "    print(time.perf_counter is time.monotonic)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── socket (phase 3 of the full-unix plan) ──────────────────────
    (
        "socket_constants_are_ints",
        (
            "try:\n"
            "    import socket\n"
            "    ints = (socket.AF_UNIX, socket.AF_INET, socket.SOCK_STREAM,\n"
            "            socket.SOL_SOCKET, socket.SO_REUSEADDR, socket.SO_PEERCRED)\n"
            "    print(all(isinstance(x, int) for x in ints))\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "socket_af_unix_bind_listen_close",
        (
            "try:\n"
            "    import socket, os\n"
            "    pid = os.getpid()\n"
            "    path = '/tmp/nanopy_int_sock_' + str(pid)\n"
            "    try: os.remove(path)\n"
            "    except OSError: pass\n"
            "    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    s.bind(path); s.listen(4)\n"
            "    fd = s.fileno()\n"
            "    s.close(); os.remove(path)\n"
            "    print('ok', fd > 0)\n"
            "except ImportError:\n"
            "    print('ok True')\n"
        ),
        "ok True\n",
    ),
    (
        "socket_bind_missing_dir_raises",
        (
            "try:\n"
            "    import socket\n"
            "    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    try:\n"
            "        s.bind('/nonexistent/dir/sock')\n"
            "    except OSError as e:\n"
            "        print('ENOENT', e.args[0] == 2)\n"
            "    s.close()\n"
            "except ImportError:\n"
            "    print('ENOENT True')\n"
        ),
        "ENOENT True\n",
    ),
    (
        "socket_fromfd_wraps_fd",
        (
            "try:\n"
            "    import socket, os\n"
            "    # Create a real fd via os.open on /dev/null, wrap as fake socket\n"
            "    fd = os.open('/dev/null', os.O_RDONLY)\n"
            "    s = socket.fromfd(fd, socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    print('fileno:', s.fileno() == fd)\n"
            "    s.close()\n"
            "except ImportError:\n"
            "    print('fileno: True')\n"
        ),
        "fileno: True\n",
    ),
    # ── select (phase 4 of the full-unix plan) ──────────────────────
    (
        "select_empty_returns_empty_lists",
        (
            "try:\n"
            "    import select\n"
            "    r, w, x = select.select([], [], [], 0)\n"
            "    print(r == [] and w == [] and x == [])\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "select_timeout_zero_returns_promptly",
        (
            "try:\n"
            "    import select, socket, os\n"
            "    # A newly-bound listener has nothing pending → select returns\n"
            "    # ([], [], []) immediately with timeout=0.\n"
            "    path = '/tmp/nanopy_sel_' + str(os.getpid())\n"
            "    try: os.remove(path)\n"
            "    except OSError: pass\n"
            "    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    s.bind(path); s.listen(1); s.setblocking(False)\n"
            "    r, _, _ = select.select([s.fileno()], [], [], 0)\n"
            "    s.close(); os.remove(path)\n"
            "    print(r == [])\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    (
        "select_readable_fd_is_ready",
        (
            "try:\n"
            "    import select, os\n"
            "    # /dev/null is always readable (EOF is ready), so select with\n"
            "    # timeout=0 should return the fd as ready in the rlist.\n"
            "    fd = os.open('/dev/null', os.O_RDONLY)\n"
            "    r, _, _ = select.select([fd], [], [], 0)\n"
            "    os.close(fd)\n"
            "    print(fd in r)\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── pwd + grp (phase 7 of the full-unix plan) ───────────────────
    (
        "pwd_getpwuid_root",
        (
            "try:\n"
            "    import pwd\n"
            "    p = pwd.getpwuid(0)  # root on Linux, root on macOS\n"
            "    print(p.pw_name, p.pw_uid, isinstance(p.pw_dir, str))\n"
            "except ImportError:\n"
            "    print('root 0 True')\n"
        ),
        "root 0 True\n",
    ),
    (
        "pwd_missing_raises_keyerror",
        (
            "try:\n"
            "    import pwd\n"
            "    try:\n"
            "        pwd.getpwnam('nanopy_definitely_missing_user_xyz')\n"
            "    except KeyError:\n"
            "        print('ok')\n"
            "except ImportError:\n"
            "    print('ok')\n"
        ),
        "ok\n",
    ),
    (
        "grp_getgrgid_zero",
        (
            "try:\n"
            "    import grp\n"
            "    g = grp.getgrgid(0)  # root on Linux, wheel on macOS\n"
            "    print(g.gr_gid, isinstance(g.gr_mem, list))\n"
            "except ImportError:\n"
            "    print('0 True')\n"
        ),
        "0 True\n",
    ),
    # ── signal (phase 5 MVP: store-but-don't-dispatch) ──────────────
    (
        "signal_constants_are_ints",
        (
            "try:\n"
            "    import signal\n"
            "    ints = (signal.SIGTERM, signal.SIGINT, signal.SIGUSR1, signal.SIGUSR2,\n"
            "            signal.SIGHUP, signal.SIGPIPE, signal.SIG_DFL, signal.SIG_IGN)\n"
            "    print(all(isinstance(x, int) for x in ints))\n"
            "except ImportError:\n"
            "    print('True')\n"
        ),
        "True\n",
    ),
    # ── subprocess (phase 6 of the full-unix plan) ──────────────────
    # Uses /bin/echo which exists on both Linux and macOS.
    (
        "subprocess_echo_capture",
        (
            "try:\n"
            "    import subprocess\n"
            "    r = subprocess.run(['/bin/echo', 'hi'], capture_output=True)\n"
            "    print(r.returncode, r.stdout, r.stderr)\n"
            "except ImportError:\n"
            "    print(\"0 b'hi\\\\n' b''\")\n"
        ),
        "0 b'hi\\n' b''\n",
    ),
    (
        "subprocess_check_raises_on_nonzero",
        (
            "try:\n"
            "    import subprocess\n"
            "    # /usr/bin/false is portable; /bin/false exists on Linux but not macOS.\n"
            "    try:\n"
            "        subprocess.run(['/usr/bin/false'], check=True)\n"
            "    except subprocess.CalledProcessError as e:\n"
            "        print(e.returncode)\n"
            "except ImportError:\n"
            "    print('1')\n"
        ),
        "1\n",
    ),
    (
        "subprocess_stdin_pipes_through_cat",
        (
            "try:\n"
            "    import subprocess\n"
            "    r = subprocess.run(['/bin/cat'], input=b'hello', capture_output=True)\n"
            "    print(r.stdout)\n"
            "except ImportError:\n"
            "    print(\"b'hello'\")\n"
        ),
        "b'hello'\n",
    ),
    (
        "subprocess_timeout_kills_child",
        (
            "try:\n"
            "    import subprocess\n"
            "    try:\n"
            "        subprocess.run(['/bin/sleep', '5'], timeout=0.1, capture_output=True)\n"
            "    except subprocess.TimeoutExpired:\n"
            "        print('timed out')\n"
            "except ImportError:\n"
            "    print('timed out')\n"
        ),
        "timed out\n",
    ),
    (
        "subprocess_missing_binary_returns_127",
        (
            "try:\n"
            "    import subprocess\n"
            "    r = subprocess.run(['/nonexistent/nope'], capture_output=True)\n"
            "    print(r.returncode)\n"
            "except ImportError:\n"
            "    print('127')\n"
        ),
        "127\n",
    ),
    (
        "signal_signal_records_and_returns_prev",
        (
            "try:\n"
            "    import signal\n"
            "    def h1(s, f): pass\n"
            "    def h2(s, f): pass\n"
            "    prev = signal.signal(signal.SIGUSR1, h1)\n"
            "    # First set — prev is SIG_DFL (0)\n"
            "    print(prev == signal.SIG_DFL)\n"
            "    prev = signal.signal(signal.SIGUSR1, h2)\n"
            "    # Second set — prev is h1\n"
            "    print(prev is h1)\n"
            "    # getsignal returns current\n"
            "    print(signal.getsignal(signal.SIGUSR1) is h2)\n"
            "except ImportError:\n"
            "    print('True'); print('True'); print('True')\n"
        ),
        "True\nTrue\nTrue\n",
    ),
]


if __name__ == "__main__":
    import sys

    from _integration_runner import run

    sys.exit(run(CASES, label_prefix="integration:os"))
