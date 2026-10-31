/*
 * NAL framing + hardware profile guard: behavioural tests.
 *
 * Both rules exist because a hardware decoder "accepts" a stream it cannot
 * decode -- MediaCodec takes every AVCC packet and dequeues nothing, and a
 * 10-bit H.264 picture reaches the hardware context and then stalls at one
 * frame per second.  Neither shows up as an error, so the only protection is
 * that the decisions themselves are correct.
 *
 * These functions are plain C with no platform headers, which is what makes
 * them testable here: this machine has no VideoToolbox and no MediaCodec, so
 * without this binary the two conversion routines and the profile list would
 * only ever be checked by grep.  tool/check_all.py runs this executable.
 *
 * Exit code 0 = every case passed.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"

static int failures;

static void fail(const char *why, const char *detail)
{
    fprintf(stderr, "FAIL %s: %s\n", why, detail);
    failures++;
}

static void expect_int(const char *why, int got, int want)
{
    if (got != want) {
        char detail[128];
        snprintf(detail, sizeof(detail), "got %d, want %d", got, want);
        fail(why, detail);
    }
}

static void expect_size(const char *why, size_t got, size_t want)
{
    if (got != want) {
        char detail[128];
        snprintf(detail, sizeof(detail), "got %zu, want %zu", got, want);
        fail(why, detail);
    }
}

static void expect_bytes(const char *why, const uint8_t *got, const uint8_t *want, size_t n)
{
    if (memcmp(got, want, n) != 0) {
        fail(why, "byte contents differ");
    }
}

/* Four byte start code + one slice, then a second NAL.  Walking this as a
 * length chain reads 1 as the first length (00 00 00 01), validates one byte of
 * payload and then hits 0x888421FF, which runs past the end -- so it is not a
 * chain, which is exactly what tells the two shapes apart. */
static const uint8_t kAnnexB[] = {
    0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21, 0xFF,
    0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E,
};

/* The packet from movie-03.mkv that started all of this: 489 bytes holding one
 * 485 byte slice, so its length field is 00 00 01 e5 and the first four bytes
 * look exactly like a three byte start code followed by one byte of payload. */
static void test_ambiguous_length_prefix(void)
{
    uint8_t packet[489];
    memset(packet, 0x5A, sizeof(packet));
    packet[0] = 0x00;
    packet[1] = 0x00;
    packet[2] = 0x01;
    packet[3] = 0xE5;
    packet[4] = 0x65; /* IDR slice header, a known NAL type */
    expect_int("length prefixed packet starting 00 00 01 is not Annex-B",
               lp_nal_is_annexb(packet, sizeof(packet)), 0);

    /* The same bytes really are Annex-B if the length field is a start code and
     * the rest parses as a chain-free payload. */
    expect_int("start code packet is Annex-B", lp_nal_is_annexb(kAnnexB, sizeof(kAnnexB)), 1);
    expect_int("four bytes is too short to tell", lp_nal_is_annexb(kAnnexB, 3), 0);
    expect_int("NULL is not Annex-B", lp_nal_is_annexb(NULL, 32), 0);
    expect_int("no start code at all is not Annex-B", lp_nal_is_annexb((const uint8_t *)"abcd", 4), 0);
}

static void test_avcc_to_annexb(void)
{
    /* two NALs: a 3 byte slice and a 2 byte SEI */
    static const uint8_t avcc[] = {
        0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84,
        0x00, 0x00, 0x00, 0x02, 0x06, 0x05,
    };
    static const uint8_t want[] = {
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
        0x00, 0x00, 0x00, 0x01, 0x06, 0x05,
    };
    uint8_t out[64];
    memset(out, 0, sizeof(out));
    size_t n = lp_nal_avcc_to_annexb(avcc, sizeof(avcc), out, sizeof(out));
    expect_size("avcc -> annexb length", n, sizeof(want));
    expect_bytes("avcc -> annexb bytes", out, want, sizeof(want));
    expect_int("converted packet is Annex-B", lp_nal_is_annexb(out, n), 1);

    /* A length that runs past the end must not produce a partial conversion:
     * half a packet is worse than no packet, because MediaCodec would accept it
     * and decode garbage from that point on. */
    static const uint8_t truncated[] = {0x00, 0x00, 0x00, 0x40, 0x65, 0x01};
    expect_size("truncated chain rejects", lp_nal_avcc_to_annexb(truncated, sizeof(truncated), out,
                                                                sizeof(out)), 0);
    static const uint8_t zero_length[] = {0x00, 0x00, 0x00, 0x00, 0x65};
    expect_size("zero length rejects", lp_nal_avcc_to_annexb(zero_length, sizeof(zero_length), out,
                                                            sizeof(out)), 0);
    expect_size("cap too small rejects", lp_nal_avcc_to_annexb(avcc, sizeof(avcc), out, 8), 0);
    expect_size("NULL rejects", lp_nal_avcc_to_annexb(NULL, 16, out, sizeof(out)), 0);
}

static void test_annexb_to_avcc(void)
{
    uint8_t out[64];
    memset(out, 0, sizeof(out));
    size_t n = lp_nal_annexb_to_avcc(kAnnexB, sizeof(kAnnexB), out, sizeof(out));
    /* Two NALs: 5 byte and 4 byte payloads, plus two 4 byte lengths. */
    expect_size("annexb -> avcc length", n, sizeof(kAnnexB));
    static const uint8_t want[] = {
        0x00, 0x00, 0x00, 0x05, 0x65, 0x88, 0x84, 0x21, 0xFF,
        0x00, 0x00, 0x00, 0x04, 0x67, 0x42, 0x00, 0x1E,
    };
    expect_bytes("annexb -> avcc bytes", out, want, sizeof(want));
    expect_int("result is a length chain, not Annex-B", lp_nal_is_annexb(out, n), 0);

    /* Three byte start codes grow a byte each, which is why the converter needs
     * headroom: 2 + 2 payload + 4 = 8 bytes, one more than the source. */
    static const uint8_t short_codes[] = {0x00, 0x00, 0x01, 0x65, 0x88};
    n = lp_nal_annexb_to_avcc(short_codes, sizeof(short_codes), out, sizeof(out));
    expect_size("3 byte start code grows to 4", n, 6);
    static const uint8_t short_want[] = {0x00, 0x00, 0x00, 0x02, 0x65, 0x88};
    expect_bytes("3 byte start code bytes", out, short_want, sizeof(short_want));

    expect_size("no start code rejects", lp_nal_annexb_to_avcc((const uint8_t *)"abcdef", 6, out,
                                                              sizeof(out)), 0);
    expect_size("too short rejects", lp_nal_annexb_to_avcc(kAnnexB, 3, out, sizeof(out)), 0);
    expect_size("NULL rejects", lp_nal_annexb_to_avcc(kAnnexB, sizeof(kAnnexB), NULL, 0), 0);
}

static void test_round_trip(void)
{
    /* Annex-B in, Annex-B out: the 4 byte start code path has to be lossless,
     * because that is the shape Matroska hands to VideoToolbox. */
    uint8_t avcc[64];
    uint8_t back[64];
    size_t n = lp_nal_annexb_to_avcc(kAnnexB, sizeof(kAnnexB), avcc, sizeof(avcc));
    if (n == 0) {
        fail("round trip", "annexb -> avcc produced nothing");
        return;
    }
    size_t m = lp_nal_avcc_to_annexb(avcc, n, back, sizeof(back));
    expect_size("round trip length", m, sizeof(kAnnexB));
    expect_bytes("round trip bytes", back, kAnnexB, sizeof(kAnnexB));
}

static void test_payload_len(void)
{
    /* Payload of the first NAL: everything between the start code and the next
     * one, which is where the converters stop. */
    expect_size("first payload", lp_nal_payload_len(kAnnexB, sizeof(kAnnexB), 4), 5);
    expect_size("second payload", lp_nal_payload_len(kAnnexB, sizeof(kAnnexB), 13), 4);
    expect_size("no following start code means the rest",
                lp_nal_payload_len((const uint8_t *)"abcd", 4, 1), 3);
}

static void test_profile_guard(void)
{
    /* The four H.264 profiles that stall every backend. */
    expect_int("H.264 High 10 refused",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_HIGH_10, 0), 1);
    expect_int("H.264 High 10 Intra refused",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_HIGH_10_INTRA, 1), 1);
    expect_int("H.264 High 4:2:2 refused",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_HIGH_422, 0), 1);
    expect_int("H.264 High 4:4:4 refused",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_HIGH_444_PREDICTIVE, 0),
               1);
    /* 8-bit H.264 must stay on the hardware path: refusing it would push every
     * ordinary film through software for no reason. */
    expect_int("H.264 High stays hardware",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_HIGH, 1), 0);
    expect_int("H.264 Baseline stays hardware",
               lp_hw_profile_needs_software(AV_CODEC_ID_H264, AV_PROFILE_H264_BASELINE, 1), 0);

    /* 10-bit HEVC is the per-platform half of the rule: VideoToolbox and
     * MediaCodec must refuse it, D3D11VA decodes it fine. */
    expect_int("HEVC Main 10 refused on Apple/Android",
               lp_hw_profile_needs_software(AV_CODEC_ID_HEVC, AV_PROFILE_HEVC_MAIN_10, 1), 1);
    expect_int("HEVC Main 10 allowed on Windows",
               lp_hw_profile_needs_software(AV_CODEC_ID_HEVC, AV_PROFILE_HEVC_MAIN_10, 0), 0);
    expect_int("HEVC Main stays hardware everywhere",
               lp_hw_profile_needs_software(AV_CODEC_ID_HEVC, AV_PROFILE_HEVC_MAIN, 1), 0);

    /* Unrelated codecs are never the guard's business. */
    expect_int("VP9 untouched",
               lp_hw_profile_needs_software(AV_CODEC_ID_VP9, AV_PROFILE_HEVC_MAIN_10, 1), 0);
    expect_int("AV1 untouched",
               lp_hw_profile_needs_software(AV_CODEC_ID_AV1, AV_PROFILE_H264_HIGH_10, 1), 0);
}

int main(void)
{
    test_ambiguous_length_prefix();
    test_avcc_to_annexb();
    test_annexb_to_avcc();
    test_round_trip();
    test_payload_len();
    test_profile_guard();

    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall nal framing and profile guard cases passed\n");
    return 0;
}
