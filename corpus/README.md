# corpus/ — packet corpus (Phase 2)

The shared test packets for both the golden [`model/`](../model/README.md) and the
RTL [`tb/`](../tb/README.md). Built with scapy. Must include malformed / adversarial
cases, not just happy paths:

- IPv4 `ihl` = 0 / 15, options present
- IPv6 extension-header chains, and chains running past end-of-frame
- TLV `len` = 0 and length overflow
- stacked 802.1Q VLANs
- truncated frames and unaligned offsets

*Empty until Phase 2. See [`docs/phase-2-reference-model.md`](../docs/phase-2-reference-model.md).*
