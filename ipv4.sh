#!/usr/bin/env bash
#
# ipv4.sh - create HTTP / SOCKS5 proxies that use the server's IPv4 addresses.
#
# With several IPv4 addresses (additional IPs or a subnet from your provider)
# the proxies are spread over them, so they leave the server from different
# IPs. With a single address all proxies share it.
#
# Shortcut for "multi-proxy.sh install ipv4"; it accepts the same commands
# and options (see "ipv4.sh --help").
#
# Quick start (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv4.sh)

set -euo pipefail

readonly MODE="ipv4"
readonly ENGINE_URL="https://raw.githubusercontent.com/maksqi/multi-proxy/main/multi-proxy.sh"

# Use multi-proxy.sh next to this file (cloned repository). When this script
# was piped in ("bash <(curl ...)") there is no such file, so download it.
engine="$(dirname "${BASH_SOURCE[0]}")/multi-proxy.sh"
if [[ ! -f $engine ]]; then
  engine=$(mktemp)
  trap 'rm -f "$engine"' EXIT
  curl -fsSL --retry 3 "$ENGINE_URL" -o "$engine" \
    || { echo "ERROR: could not download ${ENGINE_URL}" >&2; exit 1; }
fi

# "ipv4.sh [command] [options]" -> "multi-proxy.sh <command> ipv4 [options]".
cmd=install
if (( $# > 0 )) && [[ $1 != -* ]]; then
  cmd=$1
  shift
fi
bash "$engine" "$cmd" "$MODE" "$@"
