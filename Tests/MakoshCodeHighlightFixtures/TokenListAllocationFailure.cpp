#include "TokenList.h"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <new>

namespace {
int remaining = -1;
std::size_t live = 0;
}

void* operator new(std::size_t bytes) {
    if (remaining == 0) throw std::bad_alloc();
    if (remaining > 0) --remaining;
    void* result = std::malloc(bytes ? bytes : 1);
    if (!result) throw std::bad_alloc();
    ++live;
    return result;
}

void operator delete(void* pointer) noexcept {
    if (pointer) { --live; std::free(pointer); }
}
void operator delete(void* pointer, std::size_t) noexcept { ::operator delete(pointer); }

// This executable isolates allocation failure; the real node quota is tested
// separately through the app's C ABI. No production fault API is introduced.
void mk_prisma_nodes(std::size_t) {}

int main() {
    for (int cutoff = 0; cutoff <= 2; ++cutoff) {
        const std::size_t before = live;
        remaining = cutoff;
        bool failed = false;
        try { TokenList value("x"); }
        catch (const std::bad_alloc&) { failed = true; }
        remaining = -1;
        if (failed != (cutoff < 2)) {
            std::fprintf(stderr, "Wrong constructor outcome at allocation cutoff %d\n", cutoff);
            return 2;
        }
        if (live != before) {
            std::fprintf(stderr, "Constructor leaked %zu native blocks at allocation cutoff %d\n", live - before, cutoff);
            return 1;
        }
    }
    return 0;
}
