#include <libopenmpt/libopenmpt.h>
#include <stdint.h>

// Tiny acquire/release helpers for PinballAudio's lock-free single-producer /
// single-consumer command ring. They live here because the package targets
// macOS 14 (the Swift `Synchronization` module's Atomic needs macOS 15) and this
// is the only C module PinballAudio owns. Operate on plain word-sized memory.
static inline intptr_t ep_atomic_load_acquire(const intptr_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void ep_atomic_store_release(intptr_t *p, intptr_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}
