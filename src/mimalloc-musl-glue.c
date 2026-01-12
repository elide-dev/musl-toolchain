/*
 * mimalloc-musl-glue.c
 * 
 * Glue code to integrate mimalloc as musl's allocator.
 * Provides the __libc_* internal allocation functions that musl's
 * dynamic linker (ldso/dynlink.c) requires.
 *
 * This file should be compiled and linked into musl when USE_MIMALLOC=yes.
 */

#include <stddef.h>
#include <mimalloc.h>

/*
 * Flags to indicate that allocator has been replaced.
 * Referenced by musl's dynamic linker to detect allocator replacement.
 * Must be hidden visibility to match musl's expectations.
 */
__attribute__((visibility("hidden")))
int __aligned_alloc_replaced = 1;

__attribute__((visibility("hidden")))
int __malloc_replaced = 1;

/*
 * __malloc_donate - called by musl's dynamic linker to donate memory gaps
 * When using mimalloc, we simply ignore these donations since mimalloc
 * manages its own memory pools.
 */
__attribute__((visibility("hidden")))
void __malloc_donate(char *start, char *end) {
    (void)start;
    (void)end;
    /* mimalloc manages its own memory, ignore donations */
}

/*
 * Internal libc allocation functions used by musl's dynamic linker.
 * These must be provided when replacing musl's built-in allocator.
 */

void *__libc_malloc(size_t size) {
    return mi_malloc(size);
}

void *__libc_calloc(size_t count, size_t size) {
    return mi_calloc(count, size);
}

void *__libc_realloc(void *ptr, size_t size) {
    return mi_realloc(ptr, size);
}

void __libc_free(void *ptr) {
    mi_free(ptr);
}

/*
 * Standard allocation functions - redirect to mimalloc.
 * These may already be provided by mimalloc with MI_OVERRIDE, but we
 * define them here for completeness when MI_OVERRIDE is disabled.
 */

void *malloc(size_t size) {
    return mi_malloc(size);
}

void *calloc(size_t count, size_t size) {
    return mi_calloc(count, size);
}

void *realloc(void *ptr, size_t size) {
    return mi_realloc(ptr, size);
}

void free(void *ptr) {
    mi_free(ptr);
}

void *aligned_alloc(size_t alignment, size_t size) {
    return mi_aligned_alloc(alignment, size);
}

void *memalign(size_t alignment, size_t size) {
    return mi_memalign(alignment, size);
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    return mi_posix_memalign(memptr, alignment, size);
}

void *valloc(size_t size) {
    return mi_valloc(size);
}

void *pvalloc(size_t size) {
    return mi_pvalloc(size);
}

size_t malloc_usable_size(void *ptr) {
    return mi_usable_size(ptr);
}

/*
 * String duplication functions - these call malloc internally.
 */

char *strdup(const char *s) {
    return mi_strdup(s);
}

char *strndup(const char *s, size_t n) {
    return mi_strndup(s, n);
}

/*
 * reallocarray - safe realloc with overflow checking
 */
void *reallocarray(void *ptr, size_t count, size_t size) {
    return mi_reallocarray(ptr, count, size);
}
