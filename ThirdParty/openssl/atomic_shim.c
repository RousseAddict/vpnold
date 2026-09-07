/*
 * atomic_shim.c — armv7 64-bit atomic library ABI shims.
 *
 * OpenSSL 3.4.x libcrypto (threads_pthread.o) references the compiler's
 * out-of-line 64-bit atomic library functions (__atomic_*_8, generic
 * __atomic_load/__atomic_store). On armv7, 8-byte atomics are NOT lock-free,
 * so clang lowers __atomic_fetch_add(uint64_t,...) etc. to calls into these
 * library functions. Apple's iOS armv7 toolchain does not auto-link a
 * libatomic/compiler-rt providing them for a bare `clang` cross-link (Xcode
 * links them implicitly, which is why the podcold Xcode build only needed the
 * __atomic_is_lock_free stub — see atomic_stubs.S).
 *
 * These implementations are correct (global-mutex serialised). In practice
 * __atomic_is_lock_free() (atomic_stubs.S) returns 0 for size > 4, so OpenSSL
 * takes its CRYPTO_RWLOCK mutex path and these are rarely/never called — but
 * they MUST resolve at link time because the call sites are compiled in.
 *
 * Compile with -fno-builtin so clang does not reject the generic
 * __atomic_load / __atomic_store definitions as conflicting with builtins.
 */

#if defined(__arm__) && !defined(__arm64__)

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>

static pthread_mutex_t _atomic_lock = PTHREAD_MUTEX_INITIALIZER;

/*
 * Generic variants. clang refuses to let us redeclare the builtin names
 * `__atomic_load` / `__atomic_store` directly (even with -fno-builtin), so we
 * define plainly-named functions and bind them to the exact Mach-O symbols
 * (three underscores = C leading `_` + the two in the name) via an asm label.
 */
void atomicshim_load(size_t size, const void *src, void *dest, int memorder)
    __asm__("___atomic_load");
void atomicshim_store(size_t size, void *dest, void *src, int memorder)
    __asm__("___atomic_store");

void atomicshim_load(size_t size, const void *src, void *dest, int memorder)
{
    (void)memorder;
    pthread_mutex_lock(&_atomic_lock);
    memcpy(dest, src, size);
    pthread_mutex_unlock(&_atomic_lock);
}

void atomicshim_store(size_t size, void *dest, void *src, int memorder)
{
    (void)memorder;
    pthread_mutex_lock(&_atomic_lock);
    memcpy(dest, src, size);
    pthread_mutex_unlock(&_atomic_lock);
}

/* 8-byte load/store */
uint64_t __atomic_load_8(const volatile void *ptr, int memorder)
{
    uint64_t r;
    (void)memorder;
    pthread_mutex_lock(&_atomic_lock);
    r = *(const volatile uint64_t *)ptr;
    pthread_mutex_unlock(&_atomic_lock);
    return r;
}

void __atomic_store_8(volatile void *ptr, uint64_t val, int memorder)
{
    (void)memorder;
    pthread_mutex_lock(&_atomic_lock);
    *(volatile uint64_t *)ptr = val;
    pthread_mutex_unlock(&_atomic_lock);
}

/* 8-byte fetch-and-op */
#define FETCH_OP_8(name, op)                                            \
    uint64_t __atomic_fetch_##name##_8(volatile void *ptr,              \
                                       uint64_t val, int memorder)      \
    {                                                                   \
        uint64_t old;                                                   \
        (void)memorder;                                                 \
        pthread_mutex_lock(&_atomic_lock);                              \
        old = *(volatile uint64_t *)ptr;                                \
        *(volatile uint64_t *)ptr = old op val;                         \
        pthread_mutex_unlock(&_atomic_lock);                            \
        return old;                                                     \
    }

FETCH_OP_8(add, +)
FETCH_OP_8(sub, -)
FETCH_OP_8(and, &)
FETCH_OP_8(or, |)

#endif /* __arm__ && !__arm64__ */
