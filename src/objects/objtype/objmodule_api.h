/* petitpy — bc.h-free API for src/objects/objtype/objmodule.zig.
 *
 * Cleanup pass 2: inlined the MP_STATE_VM / symbol-address / mp_printf
 * wrappers into the Zig consumer via mp_mirrors + extern decls. What
 * remains is purely qstr-gen-bound: the built-in module ROM tables,
 * the delegation forwarder, an m_new_obj allocator, and a config-gated
 * MP_QSTR___file__ constant. */
#ifndef NPY_OBJMODULE_API_H
#define NPY_OBJMODULE_API_H
#include <stdint.h>
#include <stddef.h>
typedef uintptr_t npy_obj;

/* mp_obj_new_module: alloc the mp_module_context_t (m_new_obj is static
 * inline; not link-callable). */
npy_obj npy_mod_alloc_module_context(void);                 /* m_new_obj + base.type=&mp_type_module */

/* Built-in module ROM tables — qstr-gen emits MICROPY_REGISTERED_MODULES. */
void   *npy_mod_builtin_module_map(void);                  /* &mp_builtin_module_map */
void   *npy_mod_builtin_extensible_module_map(void);       /* &mp_builtin_extensible_module_map (NULL if =0) */

/* Forwarder to a static C fn that walks MODULE_DELEGATIONS ROM table. */
void    npy_mod_attr_try_delegation(npy_obj self_in, uintptr_t attr, npy_obj *dest);

/* MP_QSTR___file__ — wrapped because the qstr is only generated when
 * MICROPY_MODULE___FILE__=1; under nano (=0) it would be undefined. */
extern const uintptr_t npy_mod_QSTR_FILE;

#endif
