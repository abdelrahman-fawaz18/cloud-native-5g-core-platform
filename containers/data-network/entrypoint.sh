#!/bin/sh
set -eu

# The endpoint needs a return route for packets sourced from the UE pool. The
# UPF is the next hop on the private N6 data network.
ip route replace 10.60.0.0/24 via 10.62.0.2

exec su-exec 65532:65532 httpd -f -p 8080 -h /srv

