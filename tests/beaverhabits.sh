#!/usr/bin/env bash
set -uo pipefail

status=0

curl --fail --silent --show-error http://beaverhabits.home.arpa/ >/dev/null || status=1

ssh \
  -o 'ProxyCommand=ssh -p 2222 song@100.116.110.63 nc %h %p' \
  song@10.10.20.10 \
  'curl --fail --silent http://127.0.0.1:8500/v1/health/service/beaverhabits?passing=true | grep --quiet service:beaverhabits' || status=1

exit "$status"
