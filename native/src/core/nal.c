/*
 * NAL unit framing detection.
 *
 * A container can hand us H.264 / HEVC packets in two shapes:
 *
 *   Annex-B    every NAL prefixed by a start code, 00 00 01 or 00 00 00 01
 *   AVCC/HVCC  every NAL prefixed by its length as a 4-byte big endian number
 *
 * MP4 and most MKV files are length prefixed, raw streams and MPEG-TS are
 * start-code prefixed, and a hardware decoder wants exactly one of them.  The
 * old rule was "the packet starts with 00 00 01, so it is Annex-B", which is
 * wrong for a length-prefixed packet whose first NAL happens to be 0x0001_00xx
 * bytes long: the length reads as a start code.
 *
 * Seen in the wild: movie-03.mkv sends a 489 byte packet holding one 485 byte slice
 * whose length field is 00 00 01 e5.  Rewriting that as Annex-B shifted every
 * following byte, and VideoToolbox rejected every frame after the first one
 * with kVTVideoDecoderBadDataErr (-12909).
 *
 * So decide by validating the whole chain instead of looking at the first
 * bytes: a length-prefixed packet is one where walking the lengths lands
 * exactly on the end of the packet.  Start codes cannot fake that by accident
 * often, and a real start-code packet never validates as a chain.
 */
#include <stddef.h>
#include <stdint.h>

#include "player_internal.h"

/* Well known NAL types, capped at the HEVC range.  Anything outside means the
 * chain parsed nonsense, which is a strong hint we guessed the framing wrong. */
static int nal_type_known(uint8_t header)
{
    if (header & 0x80) {
        return 0; /* forbidden_zero_bit must be 0 in both H.264 and HEVC */
    }
    int h264 = header & 0x1f;
    int hevc = (header >> 1) & 0x3f;
    return (h264 >= 1 && h264 <= 23) || (hevc >= 0 && hevc <= 40);
}

/* Returns 1 when the packet is a valid chain of 4-byte length prefixed NALs. */
static int chain_is_valid(const uint8_t *data, size_t size)
{
    size_t i = 0;
    int units = 0;
    while (i + 4 <= size) {
        size_t len = ((size_t)data[i] << 24) | ((size_t)data[i + 1] << 16) |
                     ((size_t)data[i + 2] << 8) | (size_t)data[i + 3];
        if (len == 0 || len > size - i - 4) {
            return 0;
        }
        if (!nal_type_known(data[i + 4])) {
            return 0;
        }
        i += 4 + len;
        units++;
        if (units > 64) {
            return 0; /* not a sane access unit; stop guessing */
        }
    }
    return units > 0 && i == size;
}

static int has_start_code_at(const uint8_t *data, size_t size, size_t at)
{
    if (at + 3 > size) {
        return 0;
    }
    if (data[at] == 0 && data[at + 1] == 0 && data[at + 2] == 1) {
        return 3;
    }
    if (at + 4 <= size && data[at] == 0 && data[at + 1] == 0 && data[at + 2] == 0 &&
        data[at + 3] == 1) {
        return 4;
    }
    return 0;
}

int lp_nal_is_annexb(const uint8_t *data, size_t size)
{
    if (!data || size < 4) {
        return 0;
    }
    if (!has_start_code_at(data, size, 0)) {
        return 0;
    }
    /* A start code at the front is not enough: prove a length chain is not a
     * better fit, because that is exactly the ambiguous case above. */
    if (chain_is_valid(data, size)) {
        return 0;
    }
    return 1;
}

/* Length (in bytes) of the NAL payload that starts at `start`, or 0 when it is
 * malformed.  Used by the converters so both platforms agree on where a NAL
 * ends. */
size_t lp_nal_payload_len(const uint8_t *data, size_t size, size_t start)
{
    size_t i = start;
    while (i + 3 <= size) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] <= 1) {
            /* A 4-byte start code hides one more zero before the 1. */
            if (data[i + 2] == 1) {
                return i - start;
            }
            if (i + 3 < size && data[i + 3] == 1) {
                return i - start;
            }
        }
        i++;
    }
    return size - start;
}
