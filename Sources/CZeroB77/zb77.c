/* 0B77 static encoder over minimal libavcodec (ac3) + libavformat (spdif).
 * Mirrors the old CLI pipeline 1:1:
 *   -f s16le -ar 48000 -ac 6 -i pipe:0 -c:a ac3 -b:a Nk -ar 48000 -f spdif
 * so output must be byte-identical to it (see the golden test). */
#include "zb77.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>

#include <stdio.h>
#include <string.h>

struct zb77 {
    AVCodecContext *enc;
    AVFormatContext *fmt;
    AVIOContext *pb; /* reopened per call; see zb77_encode */
    AVFrame *frame;
    AVPacket *pkt;
    int64_t pts;
    int draining;
};

zb77_t *zb77_open(int bitrate_kbps, char *err, size_t errlen) {
    zb77_t *e = calloc(1, sizeof(*e));
    if (!e) {
        snprintf(err, errlen, "out of memory");
        return NULL;
    }
    int ret = 0;
    const AVCodec *codec = avcodec_find_encoder_by_name("ac3");
    if (!codec) {
        ret = AVERROR_ENCODER_NOT_FOUND;
        snprintf(err, errlen, "ac3 encoder not linked in");
        goto fail;
    }
    e->enc = avcodec_alloc_context3(codec);
    e->frame = av_frame_alloc();
    e->pkt = av_packet_alloc();
    if (!e->enc || !e->frame || !e->pkt) {
        ret = AVERROR(ENOMEM);
        snprintf(err, errlen, "alloc failed");
        goto fail;
    }
    e->enc->bit_rate = bitrate_kbps * 1000;
    e->enc->sample_rate = 48000;
    if (av_channel_layout_from_string(&e->enc->ch_layout, "5.1") < 0) {
        ret = AVERROR(EINVAL);
        snprintf(err, errlen, "bad channel layout");
        goto fail;
    }
    {
        const enum AVSampleFormat *fmts = NULL;
        int n = 0;
        if (avcodec_get_supported_config(NULL, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT,
                                         0, (const void **)&fmts, &n) < 0 || n < 1) {
            ret = AVERROR_ENCODER_NOT_FOUND;
            snprintf(err, errlen, "no sample formats");
            goto fail;
        }
        e->enc->sample_fmt = fmts[0];
    }
    e->enc->time_base = (AVRational){1, 48000};
    if ((ret = avcodec_open2(e->enc, codec, NULL)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    if (avformat_alloc_output_context2(&e->fmt, NULL, "spdif", NULL) < 0 || !e->fmt) {
        ret = AVERROR_MUXER_NOT_FOUND;
        snprintf(err, errlen, "spdif muxer not linked in");
        goto fail;
    }
    AVStream *st = avformat_new_stream(e->fmt, NULL);
    if (!st) {
        ret = AVERROR(ENOMEM);
        snprintf(err, errlen, "stream alloc failed");
        goto fail;
    }
    st->time_base = e->enc->time_base;
    if ((ret = avcodec_parameters_from_context(st->codecpar, e->enc)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    if ((ret = avio_open_dyn_buf(&e->pb)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    e->fmt->pb = e->pb;
    if ((ret = avformat_write_header(e->fmt, NULL)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    e->frame->nb_samples = e->enc->frame_size;
    e->frame->format = e->enc->sample_fmt;
    if ((ret = av_channel_layout_copy(&e->frame->ch_layout, &e->enc->ch_layout)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    if ((ret = av_frame_get_buffer(e->frame, 0)) < 0) {
        av_strerror(ret, err, errlen);
        goto fail;
    }
    return e;

fail:
    zb77_close(e);
    if (ret >= 0)
        ret = AVERROR_UNKNOWN;
    if (err[0] == '\0')
        av_strerror(ret, err, errlen);
    return NULL;
}

/* s16le interleave -> float planar (what the ac3 encoder eats). */
static void s16_to_fltp(const int16_t *in, AVFrame *f) {
    for (int ch = 0; ch < 6; ch++) {
        float *d = (float *)f->data[ch];
        for (int i = 0; i < 1536; i++)
            d[i] = (float)in[i * 6 + ch] / 32768.0f;
    }
}

/* Snapshot the muxer output: exactly one IEC frame per call. The dynamic
 * buffer is closed and reopened every call so bytes never accumulate. */
static int take_frame(zb77_t *e, uint8_t *spdif_out) {
    uint8_t *buf = NULL;
    int size = avio_close_dyn_buf(e->pb, &buf);
    e->pb = NULL;
    int ret = avio_open_dyn_buf(&e->pb);
    e->fmt->pb = e->pb;
    if (ret < 0) {
        av_free(buf);
        return ret;
    }
    if (size == 0) {
        av_free(buf);
        return 0;
    }
    if (size != ZB77_SPDIF_BYTES) {
        av_free(buf);
        return AVERROR_INVALIDDATA;
    }
    memcpy(spdif_out, buf, (size_t)size);
    av_free(buf);
    return ZB77_SPDIF_BYTES;
}

int zb77_encode(zb77_t *e, const int16_t *pcm6, uint8_t *spdif_out) {
    int ret;
    if (pcm6) {
        if (e->draining)
            return AVERROR(EINVAL);
        if ((ret = av_frame_make_writable(e->frame)) < 0)
            return ret;
        s16_to_fltp(pcm6, e->frame);
        e->frame->pts = e->pts;
        e->pts += 1536;
        if ((ret = avcodec_send_frame(e->enc, e->frame)) < 0)
            return ret;
    } else if (!e->draining) {
        e->draining = 1;
        if ((ret = avcodec_send_frame(e->enc, NULL)) < 0)
            return ret;
    }
    /* Collect whatever packets this input produced (0 or 1 in practice). */
    for (;;) {
        ret = avcodec_receive_packet(e->enc, e->pkt);
        if (ret == AVERROR(EAGAIN))
            break;
        if (ret < 0)
            break; /* EOF or real error — snapshot first, decide below */
        e->pkt->stream_index = 0;
        ret = av_write_frame(e->fmt, e->pkt);
        av_packet_unref(e->pkt);
        if (ret < 0)
            return ret;
    }
    int t = take_frame(e, spdif_out);
    if (t != 0)
        return t;
    if (ret == AVERROR(EAGAIN))
        return 0;
    return ret;
}

void zb77_close(zb77_t *e) {
    if (!e)
        return;
    if (e->fmt && e->pb) {
        uint8_t *buf = NULL;
        avio_close_dyn_buf(e->pb, &buf);
        av_free(buf);
    }
    avformat_free_context(e->fmt);
    avcodec_free_context(&e->enc);
    av_frame_free(&e->frame);
    av_packet_free(&e->pkt);
    free(e);
}
