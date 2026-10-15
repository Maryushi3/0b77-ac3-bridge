#pragma once
/* 0B77 static encoder: 6ch s16le in, IEC 61937 (spdif) out. No pipes. */
#include <stddef.h>
#include <stdint.h>

/* Sizes as an enum so they import into Swift (macros don't). */
enum {
    /* One input unit: 1536 frames of interleaved 6ch s16le. */
    ZB77_PCM_BYTES = 1536 * 6 * 2,
    /* One output unit: a complete IEC 61937 frame (1536 stereo s16 samples). */
    ZB77_SPDIF_BYTES = 1536 * 4
};

typedef struct zb77 zb77_t;

/* Returns NULL on failure with err filled in. */
zb77_t *zb77_open(int bitrate_kbps, char *err, size_t errlen);

/*
 * Feed exactly one input unit and collect output.
 * pcm6 == NULL: drain mode (call until it returns negative).
 * Returns ZB77_SPDIF_BYTES (frame in spdif_out), 0 (need more input),
 * or a negative AVERROR (incl. AVERROR_EOF when drained).
 */
int zb77_encode(zb77_t *e, const int16_t *pcm6, uint8_t *spdif_out);

void zb77_close(zb77_t *e);
