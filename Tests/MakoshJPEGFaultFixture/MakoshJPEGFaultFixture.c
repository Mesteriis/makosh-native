#include "MakoshJPEGFaultFixture.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Test-only allocator interception: real encoder and pinned destination source.
 * Keep completed frees as tombstones to observe a double-free without crashing XCTest. */
struct allocation { void *pointer; int live; };
static struct allocation allocations[64];
static unsigned used, calls, fail_at;
static int double_free;

static int active(void *pointer) {
    for (unsigned i = 0; i < used; i++)
        if (allocations[i].pointer == pointer && allocations[i].live) return (int)i;
    return -1;
}
static void *fault_malloc(size_t size) {
    if (++calls == fail_at) return NULL;
    void *pointer = malloc(size);
    if (pointer) { allocations[used++] = (struct allocation){pointer, 1}; }
    return pointer;
}
static void fault_free(void *pointer) {
    if (!pointer) return;
    int index = active(pointer);
    if (index >= 0) { allocations[index].live = 0; free(pointer); return; }
    for (unsigned i = 0; i < used; i++) {
        if (allocations[i].pointer == pointer) { double_free = 1; return; }
    }
    free(pointer); /* The wrapper's calloc-owned state is deliberately not intercepted. */
}
static void *fault_realloc(void *pointer, size_t size) {
    if (++calls == fail_at) return NULL;
    int index = active(pointer);
    void *next = realloc(pointer, size);
    if (next) {
        if (index >= 0) allocations[index].live = 0;
        allocations[used++] = (struct allocation){next, 1};
    }
    return next;
}

#define malloc fault_malloc
#define free fault_free
#define realloc fault_realloc
#define jpeg_mem_dest fixture_jpeg_mem_dest
#define jpeg_mem_dest_internal fixture_jpeg_mem_dest_internal
#define jpeg_stdio_dest fixture_jpeg_stdio_dest
#include "../../.local/jpeg-codec/Sources/CMozjpeg/jdatadst.c"
#define makosh_jpeg_encode_rgbx75 fixture_encode_rgbx75
#include "../../Sources/MakoshJPEGControl/MakoshJPEGControl.c"
#undef makosh_jpeg_encode_rgbx75
#undef jpeg_stdio_dest
#undef jpeg_mem_dest
#undef jpeg_mem_dest_internal
#undef realloc
#undef free
#undef malloc

int makosh_jpeg_fault_case(unsigned failure) {
    const size_t count = 1280 * 640 * 4;
    uint8_t *pixels = malloc(count);
    if (!pixels) return 32;
    uint32_t noise = 0x61c88647;
    for (size_t i = 0; i < count; i++) {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5;
        pixels[i] = (uint8_t)noise;
    }
    memset(allocations, 0, sizeof(allocations));
    used = calls = 0; double_free = 0; fail_at = failure;
    uint8_t *output = (uint8_t *)(uintptr_t)1;
    size_t length = 999;
    int accepted = fixture_encode_rgbx75(pixels, count, 1280, 640, 5120, &output, &length);
    free(pixels);
    int flags = 0;
    if (failure) {
        if (calls != failure) flags |= 1;
        if (accepted != 0) flags |= 2;
        if (output || length) flags |= 16;
    } else {
        if (accepted != 1 || !output || length <= 8192 || calls < 3) flags |= 2;
        if (accepted == 1) fault_free(output);
    }
    if (double_free) flags |= 4;
    for (unsigned i = 0; i < used; i++) {
        if (allocations[i].live) { flags |= 8; free(allocations[i].pointer); }
    }
    return flags;
}
