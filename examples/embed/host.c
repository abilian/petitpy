/* A host that gives Python one function and calls back a Python function
 * that uses it. Build: `zig build lib -Dconfig=full -Dfrozen-tiny=true`,
 * then cc -Izig-out/include host.c zig-out/lib/libpetitpy.a -lpthread -lm */
#include <stdio.h>
#include <string.h>

#include "petitpy.h"

static ppy_status twice(ppy_interp *py, void *userdata, size_t argc, const ppy_handle *argv, ppy_handle *result) {
    (void)userdata;
    int64_t n;
    if (argc != 1) return ppy_raise(py, "TypeError", "twice() takes one argument");
    if (ppy_to_int(py, argv[0], &n) != PPY_OK) return PPY_ERROR;
    return ppy_new_int(py, 2 * n, result);
}

/* Prints the traceback of the exception a call just raised. */
static void print_error(ppy_interp *py) {
    ppy_handle exc, text;
    const char *s;
    size_t len;
    if (ppy_fetch_error(py, &exc) == PPY_OK && ppy_format_exception(py, exc, &text) == PPY_OK &&
        ppy_to_str(py, text, &s, &len) == PPY_OK)
        fprintf(stderr, "%.*s", (int)len, s);
}

int main(void) {
    ppy_interp *py = ppy_new(NULL);
    if (py == NULL) return 1;
    ppy_define_function(py, "host", "twice", twice, NULL);

    const char *src =
        "import host\n"
        "def f(x):\n"
        "    return host.twice(x) + 1\n";
    if (ppy_exec(py, src, strlen(src), "<host>") != PPY_OK) {
        print_error(py);
        return 1;
    }

    ppy_handle f, arg, result;
    int64_t n;
    ppy_get_global(py, "f", &f);
    ppy_new_int(py, 20, &arg);
    if (ppy_call(py, f, 1, &arg, &result) != PPY_OK || ppy_to_int(py, result, &n) != PPY_OK) {
        print_error(py);
        return 1;
    }
    printf("%lld\n", (long long)n); /* 41 */

    ppy_free(py); /* releases f, arg and result too */
    return 0;
}
