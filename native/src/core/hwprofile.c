/*
 * Which profiles a hardware decoder must refuse.
 *
 * None of the three shipping hwaccels implements High 10 / High 4:2:2 /
 * High 4:4:4 H.264, and a rejection is not how it fails: libavcodec falls back
 * to software *inside* the hardware context, where thread_count is pinned to 1
 * because the codec still owns a device.  A 1080p 10-bit H.264 then decodes at
 * far below real time while the audio clock keeps running, so the picture
 * freezes on the first frame and only starts again once the queue is thousands
 * of packets deep.
 *
 * 10-bit HEVC is a different story per platform, measured with real files over
 * SMB:
 *
 *   D3D11VA      plays 10-bit HEVC at full speed, so Windows must NOT refuse it
 *   VideoToolbox 2-9 fps, or 0.0 fps with two decoded frames
 *   MediaCodec   accepts all 456 input buffers and dequeues none (Qin:456
 *                DQout:0/456 Render:0) -- a black frame with a walking bar
 *
 * That is why the HEVC half is a parameter: the rule itself is shared, the
 * decision to apply it is not.  The three backends used to carry three hand
 * copies of this list and one of them had already drifted.
 */
#include <stddef.h>

#include "player_internal.h"

static int h264_needs_software(int profile)
{
    /* High 10, High 4:2:2, High 4:4:4 and their predictive variants. */
    return profile == AV_PROFILE_H264_HIGH_10 || profile == AV_PROFILE_H264_HIGH_10_INTRA ||
           profile == AV_PROFILE_H264_HIGH_422 || profile == AV_PROFILE_H264_HIGH_422_INTRA ||
           profile == AV_PROFILE_H264_HIGH_444_PREDICTIVE || profile == AV_PROFILE_H264_HIGH_444_INTRA;
}

int lp_hw_profile_needs_software(int codec_id, int profile, int refuse_hevc)
{
    if (codec_id == AV_CODEC_ID_H264) {
        return h264_needs_software(profile);
    }
    if (refuse_hevc && codec_id == AV_CODEC_ID_HEVC) {
        return profile == AV_PROFILE_HEVC_MAIN_10 || profile == AV_PROFILE_HEVC_MAIN_STILL_PICTURE ||
               profile == AV_PROFILE_HEVC_REXT;
    }
    return 0;
}
