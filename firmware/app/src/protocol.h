#ifndef KEEPSAKE_PROTOCOL_H
#define KEEPSAKE_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define KS_RATE 16000U
#define KS_BLOCK_MS 100U
#define KS_BLOCK_BYTES (KS_RATE * KS_BLOCK_MS / 1000U * 2U)
#define KS_HEADER_BYTES 5U
#define KS_MAX_PAYLOAD 232U
#define KS_INFO_BYTES 20U
static inline void ks_put32(uint32_t value, uint8_t *out)
{
    for (unsigned i = 0; i < 4; ++i) { out[i] = (uint8_t)(value >> (8U * i)); }
}
static inline size_t ks_payload(uint16_t mtu)
{
    if (mtu <= 3U + KS_HEADER_BYTES + 1U) { return 0; }
    size_t bytes = mtu - 3U - KS_HEADER_BYTES;
    if (bytes > KS_MAX_PAYLOAD) { bytes = KS_MAX_PAYLOAD; }
    return bytes & ~(size_t)1; /* Complete PCM16 samples, without changing samples. */
}
static inline uint32_t ks_packet_count(size_t bytes, size_t payload)
{
    return payload ? (uint32_t)((bytes + payload - 1U) / payload) : 0;
}
/* Read-only descriptor; fits a default ATT read (22 bytes). */
static inline void ks_stream_info(uint8_t out[KS_INFO_BYTES], uint32_t boot_id)
{
    memcpy(out, "KSR1", 4);
    ks_put32(KS_RATE, out + 4);
    out[8] = KS_BLOCK_MS; out[9] = 0;
    out[10] = 1; out[11] = 16; out[12] = KS_HEADER_BYTES;
    out[13] = 1; /* bit 0: no software audio processing */
    out[14] = 0; /* hardware gain in dB */
    out[15] = 0;
    ks_put32(boot_id, out + 16);
}
#endif
