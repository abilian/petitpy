/* Checks of the embedding API (include/petitpy.h) against libpetitpy.a:
 * `make test-embed`, which also runs it under NPY_GC_STRESS so that every
 * value held only through a handle survives collections. */
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "petitpy.h"

static int failed;

static void check(const char *name, int ok) {
    printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
    failed |= !ok;
}

/* Is h a str equal to want? */
static int str_is(ppy_interp *py, ppy_handle h, const char *want) {
    const char *s;
    size_t n;
    return ppy_to_str(py, h, &s, &n) == PPY_OK && n == strlen(want) && memcmp(s, want, n) == 0;
}

static ppy_status twice(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)userdata;
    int64_t n;
    if (argc != 1) return ppy_raise(py, "TypeError", "twice() takes one argument");
    if (ppy_to_int(py, argv[0], &n) != PPY_OK) return PPY_ERROR;
    return ppy_new_int(py, 2 * n, result);
}

/* Calls back into the interpreter: Python -> host -> Python. */
static ppy_status apply(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)userdata;
    if (argc != 2) return ppy_raise(py, "TypeError", "apply() takes two arguments");
    return ppy_call(py, argv[0], 1, &argv[1], result);
}

/* Fetches an exception, inspects it, and raises the same object again. */
static ppy_status reraise(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)userdata, (void)argc, (void)argv, (void)result;
    ppy_handle exc;
    const char *src = "raise KeyError('kept')";
    if (ppy_exec(py, src, strlen(src), "<test>") != PPY_ERROR || ppy_fetch_error(py, &exc) != PPY_OK) return PPY_OK;
    if (strcmp(ppy_type_name(py, exc), "KeyError") != 0) return PPY_OK;
    return ppy_raise_exception(py, exc);
}

static ppy_status count(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)py, (void)argc, (void)argv, (void)result;
    ++*(int *)userdata;
    return PPY_OK;
}

/* Output captured by write(): each write as "<fd>:<data>|". */
static char captured[256];

static void capture(void *userdata, int fd, const char *data, size_t len) {
    size_t n = strlen(captured);
    snprintf(captured + n, sizeof captured - n, "%d:%.*s|", fd, (int)len, data);
    ++*(int *)userdata;
}

static void *worker(void *arg) {
    ppy_interp *py = arg;
    for (int i = 0; i < 200; i++) {
        ppy_handle r = 0;
        if (ppy_eval(py, "len([str(i) for i in range(50)])", 32, &r) != PPY_OK) return "eval failed";
        ppy_release(py, r);
    }
    return NULL;
}

static ppy_interp *other;

/* Calls into another interpreter: Python -> host -> other's Python. */
static ppy_status ask_other(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)userdata, (void)argc, (void)argv;
    ppy_handle r;
    int64_t n;
    if (ppy_eval(other, "x * 2", 5, &r) != PPY_OK || ppy_to_int(other, r, &n) != PPY_OK) return ppy_raise(py, "RuntimeError", "other failed");
    ppy_release(other, r);
    return ppy_new_int(py, n, result);
}

static ppy_status exec(ppy_interp *py, const char *src) {
    return ppy_exec(py, src, strlen(src), "<test>");
}

int main(void) {
    check("api version", ppy_api_version() == PPY_API_VERSION);

    const char *path[] = {"/nonexistent"};
    const char *argv[] = {"host", "-v"};
    ppy_config config = {.path = path, .path_len = 1, .argv = argv, .argc = 2};
    ppy_interp *py = ppy_new(&config);
    check("new", py != NULL);

    ppy_handle r = 0, h = 0, a = 0, b = 0;
    int64_t n = 0;
    double d = 0;
    size_t len = 0;

    check("exec", exec(py, "import sys\nx = 6 * 7\nargs = sys.argv\npath = sys.path\n") == PPY_OK);
    check("get_global", ppy_get_global(py, "x", &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 42);
    check("type_name", strcmp(ppy_type_name(py, r), "int") == 0);
    ppy_release(py, r);
    check("argv", ppy_eval(py, "args", 4, &r) == PPY_OK && ppy_repr(py, r, &h) == PPY_OK && str_is(py, h, "['host', '-v']"));
    check("sys.path is the config's", ppy_eval(py, "path", 4, &r) == PPY_OK && ppy_repr(py, r, &h) == PPY_OK && str_is(py, h, "['/nonexistent']"));

    check("frozen stdlib import", ppy_import(py, "json", &h) == PPY_OK && ppy_getattr(py, h, "dumps", &a) == PPY_OK);
    check("new_dict, setitem", ppy_new_dict(py, &b) == PPY_OK && ppy_new_str(py, "k", 1, &r) == PPY_OK && ppy_new_float(py, 1.5, &h) == PPY_OK && ppy_setitem(py, b, r, h) == PPY_OK);
    check("call", ppy_call(py, a, 1, &b, &r) == PPY_OK && str_is(py, r, "{\"k\": 1.5}"));
    check("getitem, to_float", ppy_new_str(py, "k", 1, &r) == PPY_OK && ppy_getitem(py, b, r, &h) == PPY_OK && ppy_to_float(py, h, &d) == PPY_OK && d == 1.5);

    ppy_handle items[3];
    ppy_new_int(py, 1, &items[0]);
    ppy_new_str(py, "two", 3, &items[1]);
    ppy_new_none(py, &items[2]);
    check("new_tuple, len", ppy_new_tuple(py, 3, items, &h) == PPY_OK && ppy_len(py, h, &len) == PPY_OK && len == 3);
    check("repr", ppy_repr(py, h, &r) == PPY_OK && str_is(py, r, "(1, 'two', None)"));
    check("new_list, set_global", ppy_new_list(py, 3, items, &h) == PPY_OK && ppy_set_global(py, "lst", h) == PPY_OK && exec(py, "lst.append(4)") == PPY_OK && ppy_len(py, h, &len) == PPY_OK && len == 4);
    check("bytes", ppy_new_bytes(py, "\0ab", 3, &h) == PPY_OK && ppy_eval(py, "b'\\0ab'", 7, &r) == PPY_OK);
    const void *data;
    check("to_bytes", ppy_to_bytes(py, r, &data, &len) == PPY_OK && len == 3 && memcmp(data, "\0ab", 3) == 0);
    check("bool", ppy_new_bool(py, true, &h) == PPY_OK && ppy_eval(py, "[]", 2, &r) == PPY_OK);
    bool t = true, f = false;
    check("to_bool", ppy_to_bool(py, h, &t) == PPY_OK && ppy_to_bool(py, r, &f) == PPY_OK && t && !f);
    check("big int", ppy_eval(py, "2**62", 5, &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == (int64_t)1 << 62);
    check("int overflow", ppy_eval(py, "2**64", 5, &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_ERROR);
    ppy_fetch_error(py, &h);
    check("overflow is OverflowError", strcmp(ppy_type_name(py, h), "OverflowError") == 0);

    /* Errors */
    check("exception", exec(py, "def f():\n    raise ValueError('boom')\nf()") == PPY_ERROR);
    check("fetch_error", ppy_fetch_error(py, &h) == PPY_OK && h != 0 && strcmp(ppy_type_name(py, h), "ValueError") == 0);
    check("fetch clears", ppy_fetch_error(py, &r) == PPY_OK && r == 0);
    check("format_exception", ppy_format_exception(py, h, &r) == PPY_OK && str_is(py, r, "Traceback (most recent call last):\n  File \"<test>\", in <module>\n  File \"<test>\", in f\nValueError: boom\n"));
    check("syntax error", exec(py, "1 +") == PPY_ERROR && ppy_fetch_error(py, &h) == PPY_OK && strcmp(ppy_type_name(py, h), "SyntaxError") == 0);
    check("raise in vendor C is caught", exec(py, "(2**100) // 0") == PPY_ERROR && ppy_fetch_error(py, &h) == PPY_OK && strcmp(ppy_type_name(py, h), "ZeroDivisionError") == 0);
    check("SystemExit", exec(py, "raise SystemExit(3)") == PPY_EXIT && ppy_exit_code(py) == 3);
    check("still running after SystemExit", ppy_eval(py, "x", 1, &r) == PPY_OK);
    check("invalid handle", ppy_to_int(py, 999999, &n) == PPY_ERROR && ppy_type_name(py, 999999) == NULL);
    check("released handle", ppy_new_int(py, 5, &h) == PPY_OK && (ppy_release(py, h), ppy_to_int(py, h, &n)) == PPY_ERROR);
    check("dup outlives release", ppy_new_str(py, "kept", 4, &h) == PPY_OK && ppy_dup(py, h, &a) == PPY_OK && a != h && (ppy_release(py, h), str_is(py, a, "kept")));
    check("missing global", ppy_get_global(py, "nope", &r) == PPY_ERROR && r == 0);
    check("not an int", ppy_new_str(py, "x", 1, &h) == PPY_OK && ppy_to_int(py, h, &n) == PPY_ERROR);

    /* Host functions */
    int calls = 0;
    check("define_function", ppy_define_function(py, "host", "twice", twice, NULL) == PPY_OK && ppy_define_function(py, "host", "apply", apply, NULL) == PPY_OK && ppy_define_function(py, "host", "count", count, &calls) == PPY_OK);
    check("Python calls the host", exec(py, "import host\ny = host.twice(21)") == PPY_OK && ppy_get_global(py, "y", &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 42);
    check("userdata, None result", exec(py, "for _ in range(3): assert host.count() is None") == PPY_OK && calls == 3);
    check("host raises", exec(py, "try:\n    host.twice()\nexcept TypeError as e:\n    msg = str(e)\n") == PPY_OK && ppy_get_global(py, "msg", &r) == PPY_OK && str_is(py, r, "twice() takes one argument"));
    check("host error propagates", exec(py, "host.twice('a')") == PPY_ERROR && ppy_fetch_error(py, &h) == PPY_OK && strcmp(ppy_type_name(py, h), "TypeError") == 0);
    check("nested calls", exec(py, "z = host.apply(lambda v: host.twice(v) + 1, 20)") == PPY_OK && ppy_get_global(py, "z", &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 41);
    check("define_function", ppy_define_function(py, "host", "reraise", reraise, NULL) == PPY_OK);
    check("raise_exception", exec(py, "try:\n    host.reraise()\nexcept KeyError as e:\n    assert e.args == ('kept',)\n") == PPY_OK);
    check("nested Python error", exec(py, "try:\n    host.apply(lambda v: 1 / v, 0)\nexcept ZeroDivisionError:\n    ok = 1\n") == PPY_OK);

    /* A second interpreter has its own modules, globals and heap. */
    other = ppy_new(NULL);
    check("second interpreter", other != NULL && exec(other, "x = 100\nclass Zork: pass\nzork = Zork()") == PPY_OK);
    check("separate globals", ppy_get_global(py, "x", &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 42 && ppy_get_global(other, "x", &h) == PPY_OK && ppy_to_int(other, h, &n) == PPY_OK && n == 100);
    check("a handle belongs to its interpreter", ppy_get_global(py, "x", &r) == PPY_OK && ppy_to_int(other, r, &n) == PPY_ERROR && ppy_type_name(other, r) == NULL);
    check("separate modules", exec(other, "import host") == PPY_ERROR && ppy_fetch_error(other, &h) == PPY_OK && h != 0);
    check("type_name in another interpreter", ppy_get_global(other, "zork", &h) == PPY_OK && ppy_eval(py, "x", 1, &r) == PPY_OK && strcmp(ppy_type_name(other, h), "Zork") == 0);
    check("host function calls another interpreter", ppy_define_function(py, "host", "ask_other", ask_other, NULL) == PPY_OK && ppy_eval(py, "host.ask_other() + 1", 20, &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 201);
    ppy_handle kept;
    check("other's handle", ppy_eval(other, "[7] * 3", 7, &kept) == PPY_OK);

    /* Values held only by handles survive many collections. */
    ppy_handle keep[100];
    for (int i = 0; i < 100; i++) {
        char src[32];
        int k = snprintf(src, sizeof src, "[%d] * %d", i, i + 1);
        ppy_eval(py, src, (size_t)k, &keep[i]);
    }
    check("garbage", exec(py, "for i in range(20000): s = str(i) * 3") == PPY_OK);
    check("garbage in the other heap", exec(other, "for i in range(20000): s = str(i) * 3") == PPY_OK);
    int intact = 1;
    for (int i = 0; i < 100; i++) {
        ppy_handle first;
        intact &= ppy_len(py, keep[i], &len) == PPY_OK && len == (size_t)i + 1;
        ppy_new_int(py, 0, &h);
        intact &= ppy_getitem(py, keep[i], h, &first) == PPY_OK && ppy_to_int(py, first, &n) == PPY_OK && n == i;
        ppy_release(py, first);
        ppy_release(py, keep[i]);
    }
    check("handles keep values alive", intact);
    check("its own handles too", ppy_len(other, kept, &len) == PPY_OK && len == 3);

    /* Calls from several threads, into one interpreter or two, take turns. */
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) pthread_create(&threads[i], NULL, worker, i % 2 ? other : py);
    int threads_ok = 1;
    for (int i = 0; i < 4; i++) {
        void *ret;
        pthread_join(threads[i], &ret);
        threads_ok &= ret == NULL;
    }
    check("threads", threads_ok);

    ppy_free(other);
    check("the first outlives the second", ppy_eval(py, "x", 1, &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 42);
    ppy_free(py);
    int writes = 0;
    ppy_config capturing = {.write = capture, .write_userdata = &writes};
    py = ppy_new(&capturing);
    check("new after free", py != NULL && ppy_eval(py, "1 + 1", 5, &r) == PPY_OK && ppy_to_int(py, r, &n) == PPY_OK && n == 2);
    check("fresh globals", ppy_get_global(py, "x", &r) == PPY_ERROR);
    check("output reaches write()", exec(py, "import sys\nprint('a', 1)\nsys.stdout.write('b')\nprint('c', file=sys.stderr)\nsys.stderr.write('d')") == PPY_OK);
    check("in order, by stream", strcmp(captured, "1:a|1: |1:1|1:\n|1:b|2:c|2:\n|2:d|") == 0 && writes == 8);
    int other_writes = 0;
    ppy_config capturing_other = {.write = capture, .write_userdata = &other_writes};
    other = ppy_new(&capturing_other);
    check("each interpreter its own write()", other != NULL && exec(other, "print('e')") == PPY_OK && other_writes == 2 && writes == 8 && exec(py, "print('f')") == PPY_OK && other_writes == 2 && writes == 10);
    ppy_free(other);
    ppy_free(py);

    printf("%s\n", failed ? "FAILED" : "all passed");
    return failed;
}
