#include "MakoshJPEGControl.h"
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <jpeglib.h>
#include <jerror.h>

struct makosh_jpeg_error {
    struct jpeg_error_mgr base;
    jmp_buf jump;
};
struct makosh_jpeg_state {
    struct jpeg_compress_struct codec;
    struct makosh_jpeg_error error;
    struct jpeg_destination_mgr destination;
    unsigned char *bytes;
    size_t capacity;
    size_t length;
};

static void makosh_jpeg_fail(j_common_ptr codec) {
    struct makosh_jpeg_error *error = (struct makosh_jpeg_error *)codec->err;
    longjmp(error->jump, 1);
}
static void makosh_jpeg_quiet(j_common_ptr codec) { (void)codec; }

static void makosh_jpeg_destination_init(j_compress_ptr codec) {
    struct makosh_jpeg_state *state = codec->client_data;
    state->bytes = malloc(4096);
    if (!state->bytes) ERREXIT1(codec, JERR_OUT_OF_MEMORY, 10);
    state->capacity = 4096;
    state->destination.next_output_byte = state->bytes;
    state->destination.free_in_buffer = state->capacity;
}
static boolean makosh_jpeg_destination_grow(j_compress_ptr codec) {
    struct makosh_jpeg_state *state = codec->client_data;
    if (state->capacity > SIZE_MAX / 2) ERREXIT1(codec, JERR_OUT_OF_MEMORY, 10);
    size_t capacity = state->capacity * 2;
    unsigned char *bytes = realloc(state->bytes, capacity);
    if (!bytes) ERREXIT1(codec, JERR_OUT_OF_MEMORY, 10);
    /* Publish live ownership immediately; a later codec error can longjmp. */
    state->bytes = bytes;
    state->destination.next_output_byte = bytes + state->capacity;
    state->destination.free_in_buffer = capacity - state->capacity;
    state->capacity = capacity;
    return TRUE;
}
static void makosh_jpeg_destination_finish(j_compress_ptr codec) {
    struct makosh_jpeg_state *state = codec->client_data;
    state->length = state->capacity - state->destination.free_in_buffer;
}

int makosh_jpeg_encode_rgbx75(const uint8_t *pixels, size_t count, uint32_t width,
                            uint32_t height, size_t stride, uint8_t **output, size_t *length) {
    if (output) *output = NULL;
    if (length) *length = 0;
    if (!output || !length || !pixels || !width || !height || width > 2560 || height > 2560 ||
        stride < (size_t)width * 4 || stride > SIZE_MAX / height || count < stride * height) return 0;
    /* Heap ownership remains defined across libjpeg's setjmp error boundary. */
    struct makosh_jpeg_state *state = calloc(1, sizeof(*state));
    if (!state) return 0;
    state->codec.err = jpeg_std_error(&state->error.base);
    state->error.base.error_exit = makosh_jpeg_fail;
    state->error.base.output_message = makosh_jpeg_quiet;
    if (setjmp(state->error.jump)) {
        jpeg_destroy_compress(&state->codec);
        free(state->bytes); free(state);
        return 0;
    }
    jpeg_create_compress(&state->codec);
    state->codec.client_data = state;
    state->destination.init_destination = makosh_jpeg_destination_init;
    state->destination.empty_output_buffer = makosh_jpeg_destination_grow;
    state->destination.term_destination = makosh_jpeg_destination_finish;
    state->codec.dest = &state->destination;
    state->codec.image_width = width; state->codec.image_height = height;
    state->codec.input_components = 4; state->codec.in_color_space = JCS_EXT_RGBX;
    jpeg_c_set_int_param(&state->codec, JINT_COMPRESS_PROFILE, JCP_FASTEST);
    jpeg_set_defaults(&state->codec);
    state->codec.arith_code = FALSE; state->codec.dct_method = JDCT_ISLOW;
    state->codec.optimize_coding = TRUE;
    jpeg_set_quality(&state->codec, 75, TRUE);
    jpeg_simple_progression(&state->codec);
    jpeg_start_compress(&state->codec, TRUE);
    while (state->codec.next_scanline < state->codec.image_height) {
        JSAMPROW row = (JSAMPROW)(pixels + (size_t)state->codec.next_scanline * stride);
        jpeg_write_scanlines(&state->codec, &row, 1);
    }
    jpeg_finish_compress(&state->codec);
    jpeg_destroy_compress(&state->codec);
    if (!state->bytes || !state->length) { free(state->bytes); free(state); return 0; }
    *output = state->bytes; *length = state->length;
    free(state);
    return 1;
}
