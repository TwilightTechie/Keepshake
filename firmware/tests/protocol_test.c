#include <assert.h>
#include <stdio.h>
#include "../app/src/protocol.h"
int main(void)
{
    uint8_t info[20];
    const uint8_t expected[20] = {0x4b,0x53,0x52,0x31,0x80,0x3e,0,0,100,0,1,16,5,1,0,0,0x78,0x56,0x34,0x12};
    ks_stream_info(info, 0x12345678);
    assert(memcmp(info, expected, 20) == 0);
    assert(ks_payload(23) == 14);
    assert(ks_payload(185) == 176);
    assert(ks_payload(247) == 232);
    assert(ks_payload(8) == 0);
    uint8_t original[KS_BLOCK_BYTES], received[KS_BLOCK_BYTES];
    for (size_t i=0; i<sizeof(original); ++i) { original[i]=(uint8_t)(i*37U); }
    for (unsigned mtu=23; mtu<=517; ++mtu) {
        size_t payload=ks_payload(mtu), offset=0;
        unsigned packets=0;
        while (offset<sizeof(original)) {
            size_t n=sizeof(original)-offset;
            if (n>payload) { n=payload; }
            assert(n + KS_HEADER_BYTES <= mtu-3U);
            assert(n % 2U == 0);
            memcpy(received+offset,original+offset,n);
            offset+=n; packets++;
        }
        assert(memcmp(original,received,sizeof(original))==0);
        assert(packets==ks_packet_count(sizeof(original),payload));
    }
    uint32_t seq=UINT32_MAX-1;
    uint32_t next=seq+ks_packet_count(KS_BLOCK_BYTES,232);
    assert(next==12); /* Reserve all fourteen packet numbers even if queue drops. */
    puts("PASS: descriptor bytes, MTU 23..517 framing, unchanged PCM, sequence reservation/wrap");
}
