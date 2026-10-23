/* petitpy embedding API (ADR 022). Experimental: may change before it is
 * declared stable.
 *
 * A host creates an interpreter and passes it to every call. Python values
 * cross the API as handles: small integers naming slots that the
 * interpreter keeps alive until ppy_release() or ppy_free(). Every
 * function that can fail returns a status; results come back through
 * output arguments.
 *
 * Calls into one interpreter take turns behind a lock that petitpy takes,
 * so a host may call from any thread. Deadlock: a host function that
 * waits for another thread which itself calls the same interpreter.
 *
 * In this version a process holds one interpreter at a time: ppy_new()
 * returns NULL while another exists.
 */
#ifndef PETITPY_H
#define PETITPY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PPY_API_VERSION 1

typedef struct ppy_interp ppy_interp;

/* 0 means no value. */
typedef uint32_t ppy_handle;

typedef enum {
    PPY_OK = 0,
    PPY_ERROR = 1, /* a Python exception: see ppy_fetch_error() */
    PPY_EXIT = 2,  /* SystemExit: see ppy_exit_code() */
} ppy_status;

/* Receives what Python writes to stdout (fd 1) or stderr (fd 2), in
 * order: print(), sys.stdout and sys.stderr, warnings. */
typedef void (*ppy_write_fn)(void *userdata, int fd, const char *data, size_t len);

typedef struct {
    const char *const *path; /* directories appended to sys.path */
    size_t path_len;
    const char *const *argv; /* sys.argv */
    size_t argc;
    ppy_write_fn write; /* NULL: the process's stdout and stderr */
    void *write_userdata;
} ppy_config;

/* A function the host gives Python. It receives its arguments as handles,
 * owned by the caller, and returns PPY_OK with *result set (0 for None),
 * or PPY_ERROR after ppy_raise() or after an API call that failed. */
typedef ppy_status (*ppy_function)(ppy_interp *py, void *userdata, size_t argc,
                                   const ppy_handle *argv, ppy_handle *result);

int ppy_api_version(void);

/* Lifetime. config may be NULL: empty sys.path and sys.argv. Standard
 * modules are compiled in; Python code imports from disk only from the
 * directories in config->path. Output goes to config->write, or else to
 * the process's stdout and stderr. */
ppy_interp *ppy_new(const ppy_config *config);
void ppy_free(ppy_interp *py); /* releases every handle */

/* Running code, in the namespace of __main__. */
ppy_status ppy_exec(ppy_interp *py, const char *src, size_t len, const char *filename);
ppy_status ppy_eval(ppy_interp *py, const char *src, size_t len, ppy_handle *result);
ppy_status ppy_import(ppy_interp *py, const char *name, ppy_handle *module);

/* Creating values. */
ppy_status ppy_new_none(ppy_interp *py, ppy_handle *result);
ppy_status ppy_new_bool(ppy_interp *py, bool value, ppy_handle *result);
ppy_status ppy_new_int(ppy_interp *py, int64_t value, ppy_handle *result);
ppy_status ppy_new_float(ppy_interp *py, double value, ppy_handle *result);
ppy_status ppy_new_str(ppy_interp *py, const char *utf8, size_t len, ppy_handle *result);
ppy_status ppy_new_bytes(ppy_interp *py, const void *data, size_t len, ppy_handle *result);
ppy_status ppy_new_list(ppy_interp *py, size_t n, const ppy_handle *items, ppy_handle *result);
ppy_status ppy_new_tuple(ppy_interp *py, size_t n, const ppy_handle *items, ppy_handle *result);
ppy_status ppy_new_dict(ppy_interp *py, ppy_handle *result);

/* Reading values. An int that does not fit a machine word (64 bits on
 * native, 32 on wasm) raises OverflowError. The pointer from ppy_to_str
 * and ppy_to_bytes stays valid while the handle is held. */
ppy_status ppy_to_bool(ppy_interp *py, ppy_handle h, bool *value); /* truth value */
ppy_status ppy_to_int(ppy_interp *py, ppy_handle h, int64_t *value);
ppy_status ppy_to_float(ppy_interp *py, ppy_handle h, double *value);
ppy_status ppy_to_str(ppy_interp *py, ppy_handle h, const char **utf8, size_t *len);
ppy_status ppy_to_bytes(ppy_interp *py, ppy_handle h, const void **data, size_t *len);
ppy_status ppy_str(ppy_interp *py, ppy_handle h, ppy_handle *result);  /* str(h) */
ppy_status ppy_repr(ppy_interp *py, ppy_handle h, ppy_handle *result); /* repr(h) */
const char *ppy_type_name(ppy_interp *py, ppy_handle h); /* NULL for a bad handle */

/* Containers: len(c), c[key], c[key] = value. */
ppy_status ppy_len(ppy_interp *py, ppy_handle c, size_t *len);
ppy_status ppy_getitem(ppy_interp *py, ppy_handle c, ppy_handle key, ppy_handle *result);
ppy_status ppy_setitem(ppy_interp *py, ppy_handle c, ppy_handle key, ppy_handle value);

/* Calls, attributes and the globals of __main__. */
ppy_status ppy_call(ppy_interp *py, ppy_handle fn, size_t argc, const ppy_handle *argv, ppy_handle *result);
ppy_status ppy_getattr(ppy_interp *py, ppy_handle obj, const char *name, ppy_handle *result);
ppy_status ppy_setattr(ppy_interp *py, ppy_handle obj, const char *name, ppy_handle value);
ppy_status ppy_get_global(ppy_interp *py, const char *name, ppy_handle *result);
ppy_status ppy_set_global(ppy_interp *py, const char *name, ppy_handle value);

ppy_status ppy_dup(ppy_interp *py, ppy_handle h, ppy_handle *copy); /* a second handle to the same value */
void ppy_release(ppy_interp *py, ppy_handle h);

/* Makes fn callable from Python as module.name; creates the module if
 * needed, so that `import module` finds it. */
ppy_status ppy_define_function(ppy_interp *py, const char *module, const char *name,
                               ppy_function fn, void *userdata);

/* Errors. After PPY_ERROR or PPY_EXIT the exception stays with the
 * interpreter until ppy_fetch_error() or the next call. */
ppy_status ppy_raise(ppy_interp *py, const char *type_name, const char *message); /* returns PPY_ERROR */
ppy_status ppy_raise_exception(ppy_interp *py, ppy_handle exception); /* raises it again; returns PPY_ERROR */
ppy_status ppy_fetch_error(ppy_interp *py, ppy_handle *exception); /* 0 if none; clears it */
ppy_status ppy_format_exception(ppy_interp *py, ppy_handle exception, ppy_handle *text);
int ppy_exit_code(ppy_interp *py); /* after PPY_EXIT */

#ifdef __cplusplus
}
#endif

#endif /* PETITPY_H */
