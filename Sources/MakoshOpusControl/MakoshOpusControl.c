#include "MakoshOpusControl.h"

int makosh_opus_configure_recording(OpusEncoder *encoder, int *lookahead) {
    if (encoder == NULL || lookahead == NULL) return OPUS_BAD_ARG;
    *lookahead = 0;
    int status = opus_encoder_ctl(encoder, OPUS_SET_BITRATE(30 * 1024));
    if (status != OPUS_OK) return status;
    status = opus_encoder_ctl(encoder, OPUS_SET_LSB_DEPTH(16));
    if (status != OPUS_OK) return status;
    return opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(lookahead));
}
