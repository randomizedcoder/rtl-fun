# nix/vivado-license-mac.nix
#
# The single, repo-recorded MAC address that the free Vivado **Basic** license
# (2026.1+) is node-locked to. Vivado 2026.1 moved to tiered licensing: even the free
# Basic tier now requires a license file that FlexLM node-locks to a NIC MAC (host ID).
# Locking to a *physical* NIC means a different license per machine; recording ONE MAC
# here instead makes a SINGLE license portable across every machine — declare a dummy
# interface carrying this MAC (nix/vivado-license-netdev.nix) and FlexLM reports the
# same host ID on `l`, `hp5`, or anywhere else.
#
# It is a **locally-administered, unicast** address: first octet 0x02 has the
# locally-administered bit set and the multicast bit clear, so it is reserved for
# private use and can never collide with a real vendor-assigned NIC. ("ca6f" nods to
# CVA6.) FlexLM host ID = this with the colons stripped: 02ca6f000001.
#
# To generate the license: AMD Product Licensing -> node-locked "Vivado Basic" (free)
# for host ID 02ca6f000001 -> drop the .lic at the box home's ~/.Xilinx/ (or set
# XILINXD_LICENSE_FILE). See docs/phase-8-status.md §"Verify-before-buy".
"02:ca:6f:00:00:01"
