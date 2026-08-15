#include "pcap.h"
#include <stdio.h>

/* Classic pcap: 24-byte global header + per-record 16-byte header. Magic
 * 0xa1b2c3d4 = same-endian, 0xd4c3b2a1 = swapped. */
static uint32_t rd32(const uint8_t *p, int swap)
{
    uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                 ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    if (swap) v = __builtin_bswap32(v);
    return v;
}

int pcap_read_first(const char *path, uint8_t *buf, size_t bufsz, uint32_t *linktype)
{
    FILE *f = fopen(path, "rb");
    if (!f) return -1;

    uint8_t gh[24];
    if (fread(gh, 1, 24, f) != 24) { fclose(f); return -2; }

    uint32_t magic = (uint32_t)gh[0] | ((uint32_t)gh[1] << 8) |
                     ((uint32_t)gh[2] << 16) | ((uint32_t)gh[3] << 24);
    int swap;
    if (magic == 0xa1b2c3d4u)      swap = 0;
    else if (magic == 0xd4c3b2a1u) swap = 1;
    else { fclose(f); return -3; }                 /* not a classic pcap */

    if (linktype) *linktype = rd32(gh + 20, swap);

    uint8_t rh[16];
    if (fread(rh, 1, 16, f) != 16) { fclose(f); return -4; }
    uint32_t incl = rd32(rh + 8, swap);            /* captured length */
    if (incl > bufsz) incl = (uint32_t)bufsz;      /* clamp to buffer */

    size_t got = fread(buf, 1, incl, f);
    fclose(f);
    if (got != incl) return -5;
    return (int)incl;
}
