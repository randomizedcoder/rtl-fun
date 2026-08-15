/* Minimal classic-pcap reader (libpcap format). Reads the first packet of a
 * capture into a caller buffer — enough to feed one-frame-per-file corpora like
 * xdp2's proto_audit pcap_templates. */
#ifndef LIBPARSERMODEL_PCAP_H
#define LIBPARSERMODEL_PCAP_H

#include <stdint.h>
#include <stddef.h>

/* Read the first packet of `path` into buf (up to bufsz). Returns the packet
 * length (>0) on success, or a negative value on error. *linktype gets the pcap
 * link-layer type (1 = Ethernet) when non-NULL. */
int pcap_read_first(const char *path, uint8_t *buf, size_t bufsz, uint32_t *linktype);

#endif
