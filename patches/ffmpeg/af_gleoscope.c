/*
 * gleoscope: a pass-through tap for Gleo's live analyzer.
 * Copyright (c) 2026 Utkarsh Tripathi
 *
 * This file is part of FFmpeg (as patched for the Gleo audio engine).
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * Copies the newest samples (first two channels, as float) into one ring buffer
 * that the player reads with ff_gleoscope_read() (exported by libmpv as
 * gleo_scope_read). The frames pass on untouched, in the format they came in,
 * so a bit-perfect chain stays bit-perfect. The FFT is done by the reader.
 * One global ring: with two players (a crossfade) the last writer wins.
 */

#include <math.h>
#include <string.h>

#include "config.h"
#include "libavutil/thread.h"
#include "libavutil/samplefmt.h"
#include "audio.h"
#include "avfilter.h"
#include "filters.h"

#define RING 65536 /* frames: 1.4 s at 44.1 kHz, 0.34 s at 192 kHz */

static AVMutex lock = AV_MUTEX_INITIALIZER;
static float ring[RING * 2];
static int64_t written;       /* frames written since start */
static int rate, channels, clips, is_float;
static uint32_t bits_or;
static double end_pts = -1;   /* stream time of the newest frame's end, in seconds */

static float take(const AVFrame *f, int c, int i, uint32_t *bits, int *clip)
{
    int planar = av_sample_fmt_is_planar(f->format);
    int n = planar ? i : i * f->ch_layout.nb_channels + c;
    const uint8_t *p = f->extended_data[planar ? c : 0];

    switch (av_get_packed_sample_fmt(f->format)) {
    case AV_SAMPLE_FMT_U8: {
        int v = p[n] - 128;
        *bits |= (uint32_t)v << 24;
        *clip += v == -128 || v == 127;
        return v / 128.f;
    }
    case AV_SAMPLE_FMT_S16: {
        int v = ((const int16_t *)p)[n];
        *bits |= (uint32_t)v << 16;
        *clip += v == INT16_MIN || v == INT16_MAX;
        return v / 32768.f;
    }
    case AV_SAMPLE_FMT_S32: {
        int32_t v = ((const int32_t *)p)[n];
        *bits |= (uint32_t)v;
        *clip += v == INT32_MIN || v == INT32_MAX;
        return v / 2147483648.f;
    }
    case AV_SAMPLE_FMT_FLT: {
        float v = ((const float *)p)[n];
        *clip += fabsf(v) >= 1.f;
        return v;
    }
    default: {
        double v = ((const double *)p)[n];
        *clip += fabs(v) >= 1.0;
        return (float)v;
    }
    }
}

static int filter_frame(AVFilterLink *inlink, AVFrame *f)
{
    int nch = f->ch_layout.nb_channels, clip = 0;
    uint32_t bits = 0;

    ff_mutex_lock(&lock);
    for (int i = 0; i < f->nb_samples; i++) {
        float *o = ring + ((written + i) % RING) * 2;
        o[0] = take(f, 0, i, &bits, &clip);
        o[1] = nch > 1 ? take(f, 1, i, &bits, &clip) : o[0];
    }
    written += f->nb_samples;
    rate      = f->sample_rate;
    channels  = nch;
    clips    += clip;
    bits_or  |= bits;
    is_float  = av_get_packed_sample_fmt(f->format) >= AV_SAMPLE_FMT_FLT;
    end_pts   = f->pts == AV_NOPTS_VALUE ? -1 :
                (f->pts + f->nb_samples) * av_q2d(inlink->time_base);
    ff_mutex_unlock(&lock);

    return ff_filter_frame(inlink->dst->outputs[0], f);
}

/**
 * Copies up to `frames` stereo float frames (L R L R ...) into out, ending
 * `ago` frames before the newest one. Returns the number copied.
 * info[6]: sample rate, input channels, full-scale samples since the last read,
 * OR of the integer samples since the last read as a 32-bit word (-1 for float
 * input), the stream time (s) of the newest frame's end (-1 if unknown), and the
 * frames written so far.
 */
int ff_gleoscope_read(float *out, int frames, int ago, double *info);
int ff_gleoscope_read(float *out, int frames, int ago, double *info)
{
    int64_t start, end;

    ff_mutex_lock(&lock);
    end   = written - FFMAX(ago, 0);
    start = FFMAX(end - FFMAX(frames, 0), FFMAX(written - RING, 0));
    for (int64_t k = start; k < end; k++)
        memcpy(out + 2 * (k - start), ring + (k % RING) * 2, 2 * sizeof(float));
    info[0] = rate;
    info[1] = channels;
    info[2] = clips;
    info[3] = is_float ? -1 : (double)bits_or;
    info[4] = end_pts;
    info[5] = (double)written;
    clips   = 0;
    bits_or = 0;
    ff_mutex_unlock(&lock);
    return end > start ? (int)(end - start) : 0;
}

static const AVFilterPad gleoscope_inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_AUDIO,
        .filter_frame = filter_frame,
    },
};

const FFFilter ff_af_gleoscope = {
    .p.name        = "gleoscope",
    .p.description = NULL_IF_CONFIG_SMALL("Copy the newest samples for Gleo's live analyzer; audio passes untouched."),
    .p.flags       = AVFILTER_FLAG_METADATA_ONLY,
    FILTER_INPUTS(gleoscope_inputs),
    FILTER_OUTPUTS(ff_audio_default_filterpad),
    FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_U8,  AV_SAMPLE_FMT_U8P,
                      AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P,
                      AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P,
                      AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP,
                      AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP),
};
