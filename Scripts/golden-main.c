/* Golden harness: file in -> zb77 frames out. Compare with the CLI pipeline. */
#include "zb77.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s in.s16 out.spdif bitrate_kbps\n", argv[0]);
        return 2;
    }
    FILE *in = fopen(argv[1], "rb");
    FILE *out = fopen(argv[2], "wb");
    int kbps = atoi(argv[3]);
    if (!in || !out) {
        perror("open");
        return 1;
    }
    char err[256] = {0};
    zb77_t *e = zb77_open(kbps, err, sizeof(err));
    if (!e) {
        fprintf(stderr, "open: %s\n", err);
        return 1;
    }
    static int16_t pcm[1536 * 6];
    static uint8_t spdif[ZB77_SPDIF_BYTES];
    size_t n;
    long frames = 0;
    while ((n = fread(pcm, 1, ZB77_PCM_BYTES, in)) == ZB77_PCM_BYTES) {
        int r = zb77_encode(e, pcm, spdif);
        if (r < 0) {
            fprintf(stderr, "encode: %d\n", r);
            return 1;
        }
        if (r == ZB77_SPDIF_BYTES) {
            fwrite(spdif, 1, (size_t)r, out);
            frames++;
        }
    }
    if (n != 0) {
        fprintf(stderr, "trailing %zu bytes (input must be a multiple of %d)\n",
                n, ZB77_PCM_BYTES);
        return 1;
    }
    for (;;) {
        int r = zb77_encode(e, NULL, spdif);
        if (r < 0)
            break; /* EOF */
        if (r == ZB77_SPDIF_BYTES) {
            fwrite(spdif, 1, (size_t)r, out);
            frames++;
        }
    }
    zb77_close(e);
    fclose(in);
    fclose(out);
    printf("wrote %ld IEC frames\n", frames);
    return 0;
}
