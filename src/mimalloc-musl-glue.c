/*
 * mimalloc-musl-glue.c
 * 
 * Glue code to integrate mimalloc with musl libc.
 * This file provides the musl-specific internal hooks and redirects
 * standard allocation functions to mimalloc.
 *
 * When linked into musl's libc.a, all allocations will transparently
 * use mimalloc as the underlying allocator.
 *
 * Build with:
 *   gcc -c -O3 -fPIC -fno-fast-math -U_FORTIFY_SOURCE \
 *       -I<sysroot>/include mimalloc-musl-glue.c -o mimalloc-musl-glue.o
 *
 * Copyright (c) 2025 Anthropic. MIT License.
 */

#include <mimalloc.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>

/* ==========================================================================
 * Musl internal hooks
 * 
 * These symbols are expected by musl's internal code (particularly the
 * dynamic linker in ldso/dynlink.c). They must be provided for musl to
 * link successfully when its native allocator is replaced.
 * ========================================================================== */

/*
 * Flag indicating the malloc implementation was replaced.
 * 
 * The dynamic linker checks this to determine whether it should call
 * __malloc_donate() to reclaim memory gaps between loaded shared objects.
 * When set to 1, ldso knows a custom allocator is in use.
 */
int __malloc_replaced = 1;

/*
 * Called by musl's dynamic linker to donate memory gaps back to the allocator.
 * 
 * When shared libraries are loaded, there are often small gaps between them
 * due to alignment requirements. Musl's native allocator can reclaim these
 * gaps for small allocations.
 * 
 * For mimalloc, we ignore this - mimalloc manages its own memory through
 * the OS and doesn't benefit from these small donated regions. The memory
 * is effectively lost (typically a few KB total), which is acceptable.
 *
 * A more complete implementation could use mi_manage_os_memory() to register
 * this memory with mimalloc's arena system, but the complexity outweighs
 * the minimal gains.
 */
void __malloc_donate(void *start, void *end)
{
    (void)start;
    (void)end;
    /* Intentionally ignored - mimalloc manages its own memory */
}

/*
 * Called by some allocation paths to check if memory is already zeroed.
 * 
 * This is used by calloc() to potentially skip the memset if the memory
 * came from a source known to be zero (e.g., fresh mmap). Since mimalloc
 * handles zeroing internally in mi_calloc(), we always return 0 here
 * to indicate "unknown" and let mimalloc do its thing.
 */
int __malloc_allzerop(void *p)
{
    (void)p;
    return 0;
}

/* ==========================================================================
 * Standard C allocation functions
 * 
 * These are the core allocation functions required by the C standard.
 * We redirect them all to mimalloc's implementations.
 * ========================================================================== */

void *malloc(size_t size)
{
    return mi_malloc(size);
}

void free(void *ptr)
{
    mi_free(ptr);
}

void *calloc(size_t nmemb, size_t size)
{
    return mi_calloc(nmemb, size);
}

void *realloc(void *ptr, size_t size)
{
    return mi_realloc(ptr, size);
}

/* ==========================================================================
 * Extended allocation functions
 * 
 * These provide additional allocation capabilities beyond the basic
 * malloc/free/calloc/realloc set.
 * ========================================================================== */

/*
 * Reallocate an array with overflow checking.
 * Returns NULL and sets errno to ENOMEM if nmemb * size overflows.
 */
void *reallocarray(void *ptr, size_t nmemb, size_t size)
{
    /* mimalloc's reallocarray handles overflow checking */
    return mi_reallocarray(ptr, nmemb, size);
}

/*
 * Allocate memory with specified alignment (legacy interface).
 * The alignment must be a power of two.
 */
void *memalign(size_t alignment, size_t size)
{
    return mi_memalign(alignment, size);
}

/*
 * C11 aligned allocation.
 * Size must be a multiple of alignment, and alignment must be a power of two.
 */
void *aligned_alloc(size_t alignment, size_t size)
{
    return mi_aligned_alloc(alignment, size);
}

/*
 * POSIX aligned allocation.
 * On success, stores the allocated pointer in *memptr and returns 0.
 * On failure, returns an error code (not via errno).
 */
int posix_memalign(void **memptr, size_t alignment, size_t size)
{
    return mi_posix_memalign(memptr, alignment, size);
}

/*
 * Allocate memory aligned to page boundary.
 * The size is NOT rounded up to a page multiple.
 */
void *valloc(size_t size)
{
    return mi_valloc(size);
}

/*
 * Allocate memory aligned to page boundary with size rounded up.
 * Both alignment and size are rounded to page size.
 * Note: This is a legacy/obsolete function but still used by some software.
 */
void *pvalloc(size_t size)
{
    return mi_pvalloc(size);
}

/* ==========================================================================
 * String functions that allocate memory
 * 
 * These string functions allocate memory and must use the same allocator
 * as malloc/free to ensure consistency.
 * ========================================================================== */

/*
 * Duplicate a string.
 * Returns a newly allocated copy of the string, or NULL on failure.
 */
char *strdup(const char *s)
{
    return mi_strdup(s);
}

/*
 * Duplicate at most n bytes of a string.
 * The result is always null-terminated.
 */
char *strndup(const char *s, size_t n)
{
    return mi_strndup(s, n);
}

/* ==========================================================================
 * Malloc introspection
 * 
 * Functions for querying allocation metadata.
 * ========================================================================== */

/*
 * Get the usable size of an allocated block.
 * This may be larger than the originally requested size due to alignment
 * or allocator overhead considerations.
 */
size_t malloc_usable_size(void *ptr)
{
    return mi_usable_size(ptr);
}

/* ==========================================================================
 * Additional musl compatibility
 * 
 * These functions may be called by various musl internals or by programs
 * expecting glibc-like behavior.
 * ========================================================================== */

/*
 * malloc_trim - release free memory back to the OS
 * 
 * In glibc, this attempts to release memory from the top of the heap.
 * mimalloc handles memory release internally and more aggressively,
 * so this is mostly a no-op but we do call mi_collect for good measure.
 *
 * Returns 1 if memory was actually released, 0 otherwise.
 * We always return 1 since mi_collect may release memory.
 */
int malloc_trim(size_t pad)
{
    (void)pad;
    mi_collect(false);  /* Don't force, just collect what's easy */
    return 1;
}

/*
 * mallopt - set malloc tuning parameters
 * 
 * This is a glibc extension for tuning allocator behavior.
 * mimalloc has its own configuration system (mi_option_*), so we
 * ignore these requests but return success to avoid breaking programs
 * that call this.
 */
int mallopt(int param, int value)
{
    (void)param;
    (void)value;
    return 1;  /* Pretend success */
}

/*
 * mallinfo/mallinfo2 - get malloc statistics
 * 
 * These are glibc extensions. We don't implement them fully but provide
 * stub implementations that return zeroed structures to avoid link errors.
 * Programs that seriously need this information should use mimalloc's
 * native mi_stats_* functions instead.
 */
struct mallinfo {
    int arena;
    int ordblks;
    int smblks;
    int hblks;
    int hblkhd;
    int usmblks;
    int fsmblks;
    int uordblks;
    int fordblks;
    int keepcost;
};

struct mallinfo mallinfo(void)
{
    struct mallinfo info = {0};
    return info;
}

/* mallinfo2 uses size_t instead of int - more accurate for large heaps */
struct mallinfo2 {
    size_t arena;
    size_t ordblks;
    size_t smblks;
    size_t hblks;
    size_t hblkhd;
    size_t usmblks;
    size_t fsmblks;
    size_t uordblks;
    size_t fordblks;
    size_t keepcost;
};

struct mallinfo2 mallinfo2(void)
{
    struct mallinfo2 info = {0};
    return info;
}
