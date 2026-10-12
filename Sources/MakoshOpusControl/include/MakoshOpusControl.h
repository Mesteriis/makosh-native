#ifndef MAKOSH_OPUS_CONTROL_H
#define MAKOSH_OPUS_CONTROL_H
#include <opus.h>

/* Borrows encoder; never owns or retains it. Fixed-signature variadic boundary. */
int makosh_opus_configure_recording(OpusEncoder *encoder, int *lookahead);
#endif
