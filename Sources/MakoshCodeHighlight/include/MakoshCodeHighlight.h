#ifndef MAKOSH_CODE_HIGHLIGHT_H
#define MAKOSH_CODE_HIGHLIGHT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MKCodeHighlightCancellation MKCodeHighlightCancellation;

typedef enum MKCodeHighlightStatus {
    MKCodeHighlightSuccess = 0,
    MKCodeHighlightUnsupported = 1,
    MKCodeHighlightAborted = 2,
    MKCodeHighlightInvalid = 3
} MKCodeHighlightStatus;

typedef struct MKCodeHighlightSpan {
    size_t offset;
    size_t length;
    /* 0 plain, 1 comment, 2 property, 3 green, 4 red, 5 purple, 6 blue. */
    uint32_t role;
} MKCodeHighlightSpan;

MKCodeHighlightCancellation *mk_code_highlight_cancellation_create(void);
void mk_code_highlight_cancellation_destroy(MKCodeHighlightCancellation *token);
/* Thread-safe. Token remains owned until the synchronous parse has returned. */
void mk_code_highlight_cancellation_cancel(MKCodeHighlightCancellation *token);

/* Length-delimited UTF-8 (embedded NUL permitted in source). Language is ASCII.
 * Output contains ordered, disjoint, positive leaf byte ranges into source.
 * Roles inherit the nearest mapped enclosing token. No transformed text.
 * Limits: source <= 131072 bytes/32768 UTF-16 units; language <= 64 bytes;
 * output <= 8192 spans. Invalid UTF-8 is rejected before grammar parsing.
 * Native also enforces aggregate matching, recursion, node and time budgets.
 * On non-success *written is zero, even when parsing had made partial progress.
 * Neither grammar/catalog/source content nor input paths may be logged.
 */
MKCodeHighlightStatus mk_code_highlight(const uint8_t *source, size_t source_length,
    const uint8_t *language, size_t language_length, MKCodeHighlightCancellation *token,
    MKCodeHighlightSpan *spans, size_t capacity, size_t *written);

#ifdef __cplusplus
}
#endif

#endif
