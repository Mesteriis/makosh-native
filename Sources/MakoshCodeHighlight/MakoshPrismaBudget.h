#ifndef MAKOSH_PRISMA_BUDGET_H
#define MAKOSH_PRISMA_BUDGET_H

#include <cstddef>

// Cooperative per-request checks used only by the exact reviewed adaptation.
// Cleanup of an already-thrown parse is deliberately exempt from new throws.
struct MKPrismaAbort {};
void mk_prisma_checkpoint(std::size_t cost = 1);
void mk_prisma_nodes(std::size_t count);
void mk_prisma_enter_depth();
void mk_prisma_leave_depth() noexcept;
bool mk_prisma_begin_cleanup() noexcept;
void mk_prisma_end_cleanup(bool previous) noexcept;

class MKPrismaDepthGuard {
public:
    MKPrismaDepthGuard() { mk_prisma_enter_depth(); }
    ~MKPrismaDepthGuard() { mk_prisma_leave_depth(); }
    MKPrismaDepthGuard(const MKPrismaDepthGuard&) = delete;
    MKPrismaDepthGuard& operator=(const MKPrismaDepthGuard&) = delete;
};

class MKPrismaCleanupGuard {
public:
    MKPrismaCleanupGuard() noexcept : previous(mk_prisma_begin_cleanup()) {}
    ~MKPrismaCleanupGuard() { mk_prisma_end_cleanup(previous); }
    MKPrismaCleanupGuard(const MKPrismaCleanupGuard&) = delete;
    MKPrismaCleanupGuard& operator=(const MKPrismaCleanupGuard&) = delete;
private:
    bool previous;
};

#endif
