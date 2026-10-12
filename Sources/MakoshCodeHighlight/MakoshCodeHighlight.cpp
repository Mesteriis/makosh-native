#include "MakoshCodeHighlight.h"
#include "MakoshPrismaBudget.h"
#include "CPrismaEngine.h"
#include "MakoshPrismaGrammar.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>
#include <thread>
#include <vector>

struct MKCodeHighlightCancellation {
    std::atomic<bool> cancelled{false};
};

namespace {
using Clock = std::chrono::steady_clock;
struct Budget {
    MKCodeHighlightCancellation *token;
    std::size_t work = 10000000;
    std::size_t nodes = 32768;
    unsigned depth = 0;
    unsigned ticks = 0;
    bool cleanup = false;
    Clock::time_point deadline = Clock::now() + std::chrono::seconds(5);
};

// Scoped to one synchronous C call; prepared regex code shares these checks.
thread_local Budget *activeBudget = nullptr;
class BudgetScope {
public:
    explicit BudgetScope(Budget& value) : previous(activeBudget) { activeBudget = &value; }
    ~BudgetScope() { activeBudget = previous; }
private:
    Budget *previous;
};

std::shared_ptr<SyntaxHighlighter> grammar() {
    static std::mutex mutex;
    static std::shared_ptr<SyntaxHighlighter> highlighter;
    while (!mutex.try_lock()) {
        mk_prisma_checkpoint();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::unique_lock<std::mutex> lock(mutex, std::adopt_lock);
    mk_prisma_checkpoint();
    if (!highlighter) {
        const std::string bytes(reinterpret_cast<const char *>(mk_prisma_grammar), mk_prisma_grammar_size);
        highlighter = std::make_shared<SyntaxHighlighter>(bytes);
    }
    return highlighter;
}

bool validUTF8(const uint8_t *source, std::size_t length) {
    std::size_t units = 0;
    for (std::size_t index = 0; index < length;) {
        const uint8_t first = source[index];
        unsigned count;
        uint32_t value;
        if (first < 0x80) { count = 1; value = first; }
        else if (first >= 0xC2 && first <= 0xDF) { count = 2; value = first & 0x1F; }
        else if (first >= 0xE0 && first <= 0xEF) { count = 3; value = first & 0x0F; }
        else if (first >= 0xF0 && first <= 0xF4) { count = 4; value = first & 7; }
        else { return false; }
        if (count > length - index) return false;
        for (unsigned offset = 1; offset < count; ++offset) {
            const uint8_t next = source[index + offset];
            if (next < 0x80 || next > 0xBF) return false;
            value = (value << 6) | (next & 0x3F);
        }
        if ((count == 2 && value < 0x80) || (count == 3 && value < 0x800) ||
            (count == 4 && value < 0x10000) || value > 0x10FFFF ||
            (value >= 0xD800 && value <= 0xDFFF)) return false;
        units += value > 0xFFFF ? 2 : 1;
        if (units > 32768) return false;
        index += count;
    }
    return true;
}

std::optional<uint32_t> role(const std::string& key) {
    if (key == "comment" || key == "block-comment" || key == "prolog" ||
        key == "doctype" || key == "cdata" || key == "punctuation") return 1;
    if (key == "property") return 2;
    if (key == "tag" || key == "boolean" || key == "number" ||
        key == "inserted" || key == "function-definition") return 3;
    if (key == "constant" || key == "symbol" || key == "deleted" ||
        key == "selector" || key == "attr-name" || key == "class-name") return 4;
    if (key == "char") return 5;
    if (key == "operator" || key == "entity" || key == "url" ||
        key == "attr-value" || key == "keyword") return 6;
    if (key == "string" || key == "builtin" || key == "atrule") return 0;
    return std::nullopt;
}

void collect(TokenList::ConstIterator begin, TokenList::ConstIterator end, uint32_t inherited,
    const std::string& source, std::size_t capacity, std::vector<MKCodeHighlightSpan>& output,
    std::size_t& cursor) {
    MKPrismaDepthGuard depth;
    for (auto it = begin; it != end; ++it) {
        mk_prisma_checkpoint();
        const auto& node = *it;
        if (node.isSyntax()) {
            const auto& syntax = static_cast<const Syntax&>(node);
            auto color = role(syntax.alias());
            if (!color) color = role(syntax.type());
            collect(syntax.begin(), syntax.end(), color.value_or(inherited), source, capacity, output, cursor);
        } else {
            const auto& text = static_cast<const Text&>(node).value();
            if (text.empty()) continue;
            const auto base = reinterpret_cast<std::uintptr_t>(source.data());
            const auto pointer = reinterpret_cast<std::uintptr_t>(text.data());
            if (pointer < base || pointer - base > source.size()) throw MKPrismaAbort();
            const std::size_t offset = pointer - base;
            if (offset != cursor || text.size() > source.size() - offset) throw MKPrismaAbort();
            cursor += text.size();
            if (!output.empty() && output.back().role == inherited &&
                output.back().offset + output.back().length == offset) {
                output.back().length += text.size();
            } else {
                if (output.size() >= capacity) throw MKPrismaAbort();
                output.push_back({offset, text.size(), inherited});
            }
        }
    }
}
} // namespace

void mk_prisma_checkpoint(std::size_t cost) {
    auto *budget = activeBudget;
    if (!budget) throw MKPrismaAbort();
    if (budget->cleanup) return;
    if (budget->token->cancelled.load(std::memory_order_relaxed) || cost > budget->work) throw MKPrismaAbort();
    budget->work -= cost;
    if ((budget->ticks++ & 255) == 0 && Clock::now() > budget->deadline) throw MKPrismaAbort();
}

void mk_prisma_nodes(std::size_t count) {
    mk_prisma_checkpoint();
    if (count > activeBudget->nodes) throw MKPrismaAbort();
    activeBudget->nodes -= count;
}

void mk_prisma_enter_depth() {
    mk_prisma_checkpoint();
    if (activeBudget->depth >= 64) throw MKPrismaAbort();
    ++activeBudget->depth;
}
void mk_prisma_leave_depth() noexcept { if (activeBudget && activeBudget->depth) --activeBudget->depth; }
bool mk_prisma_begin_cleanup() noexcept {
    if (!activeBudget) return true;
    const bool previous = activeBudget->cleanup;
    activeBudget->cleanup = true;
    return previous;
}
void mk_prisma_end_cleanup(bool previous) noexcept { if (activeBudget) activeBudget->cleanup = previous; }

MKCodeHighlightCancellation *mk_code_highlight_cancellation_create(void) {
    return new (std::nothrow) MKCodeHighlightCancellation();
}
void mk_code_highlight_cancellation_destroy(MKCodeHighlightCancellation *token) { delete token; }
void mk_code_highlight_cancellation_cancel(MKCodeHighlightCancellation *token) {
    if (token) token->cancelled.store(true, std::memory_order_relaxed);
}

MKCodeHighlightStatus mk_code_highlight(const uint8_t *source, std::size_t sourceLength,
    const uint8_t *language, std::size_t languageLength, MKCodeHighlightCancellation *token,
    MKCodeHighlightSpan *spans, std::size_t capacity, std::size_t *written) {
    if (written) *written = 0;
    if (!written || !token || (!source && sourceLength) || (!spans && capacity) ||
        !language || languageLength == 0 || languageLength > 64 || sourceLength > 131072 || capacity > 8192)
        return MKCodeHighlightInvalid;
    Budget budget{token};
    BudgetScope scope(budget);
    try {
        mk_prisma_checkpoint();
        if (!validUTF8(source, sourceLength)) return MKCodeHighlightInvalid;
        std::string hint;
        hint.reserve(languageLength);
        for (std::size_t index = 0; index < languageLength; ++index) {
            const uint8_t value = language[index];
            if (value < 0x21 || value > 0x7E) return MKCodeHighlightInvalid;
            hint.push_back(value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value);
        }
        auto highlighter = grammar();
        if (!highlighter->supports(hint)) return MKCodeHighlightUnsupported;
        budget.work = 2000000;
        budget.nodes = 32768;
        budget.ticks = 0;
        budget.deadline = Clock::now() + std::chrono::milliseconds(250);
        mk_prisma_checkpoint();
        const std::string text = sourceLength ? std::string(reinterpret_cast<const char *>(source), sourceLength) : std::string();
        auto tokens = highlighter->tokenize(text, hint);
        std::vector<MKCodeHighlightSpan> result;
        result.reserve(std::min(capacity, std::size_t(1024)));
        std::size_t cursor = 0;
        collect(tokens.begin(), tokens.end(), 0, text, capacity, result, cursor);
        if (cursor != text.size()) throw MKPrismaAbort();
        mk_prisma_checkpoint();
        if (!result.empty()) std::copy(result.begin(), result.end(), spans);
        mk_prisma_checkpoint();
        *written = result.size();
        return MKCodeHighlightSuccess;
    } catch (...) {
        // All owned native storage is unwound before publishing a status.
        *written = 0;
        return MKCodeHighlightAborted;
    }
}
