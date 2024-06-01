#!/usr/bin/env bash
#
# ipv6.sh - multi-proxy installer powered by 3proxy.
#
# Creates any number of HTTP, SOCKS5 or dual-protocol (HTTP + SOCKS5 on the
# same port) proxies on consecutive ports. In "ipv6" mode every proxy leaves
# the server from its own random IPv6 address taken from the server's /64
# subnet; in "ipv4" mode all proxies share the server's IPv4 address.
#
# Quick start (as root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv6.sh)
#
# Run "ipv6.sh --help" for all commands and options.
#
# Supported systems: Ubuntu 20.04+, Debian 11+, AlmaLinux / Rocky Linux /
# RHEL / CentOS Stream 8+, Fedora. Requires root and systemd.
#
# Project page: https://github.com/maksqi/multi-proxy

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv6.sh"

# 3proxy is built from the official source release (LTS branch).
readonly THREEPROXY_VERSION="0.9.9.0"
readonly THREEPROXY_URL="https://github.com/3proxy/3proxy/archive/refs/tags/${THREEPROXY_VERSION}.tar.gz"

readonly APP_NAME="ipv6-proxy"
readonly CONFIG_DIR="/etc/${APP_NAME}"
readonly SETTINGS_FILE="${CONFIG_DIR}/settings.env"
readonly DB_FILE="${CONFIG_DIR}/proxies.db"       # TSV: port user pass ipv6
readonly CFG_FILE="${CONFIG_DIR}/3proxy.cfg"
readonly UP_BATCH="${CONFIG_DIR}/ipv6-up.batch"   # "ip -batch" file that adds addresses
readonly DOWN_BATCH="${CONFIG_DIR}/ipv6-down.batch" # "ip -batch" file that removes them
readonly LIST_FILE="${CONFIG_DIR}/proxies.txt"
readonly URL_LIST_FILE="${CONFIG_DIR}/proxies-url.txt"
readonly VERSION_FILE="${CONFIG_DIR}/3proxy.version"

readonly BIN_3PROXY="/usr/local/bin/3proxy"
readonly SELF_BIN="/usr/local/sbin/${APP_NAME}"
readonly SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
readonly ROTATE_SERVICE_FILE="/etc/systemd/system/${APP_NAME}-rotate.service"
readonly ROTATE_TIMER_FILE="/etc/systemd/system/${APP_NAME}-rotate.timer"
readonly SYSCTL_FILE="/etc/sysctl.d/99-${APP_NAME}.conf"

readonly DEFAULT_COUNT=100
readonly DEFAULT_TYPE="both"
readonly DEFAULT_AUTH="random"
readonly DEFAULT_START_PORT=10000
readonly PROXY_MAXCONN=1000     # max simultaneous connections per proxy port
readonly USERS_PER_LINE=50      # how many accounts go on one "users" line in 3proxy.cfg

# ---------------------------------------------------------------------------
# Options (filled from the command line, interactive prompts or settings.env)
# ---------------------------------------------------------------------------

COUNT=""
PROXY_TYPE=""      # http | socks5 | both
AUTH_MODE=""       # random | single | none
PROXY_USER=""
PROXY_PASS=""
START_PORT=""
EGRESS_MODE=""     # ipv6 | ipv4
ALLOW_IPS=""       # comma-separated client IPs/CIDRs, empty = anyone
ALLOW_IPS_SET=0    # 1 when --allow-ip was given (even if empty)
IPV4_FALLBACK=0
IFACE=""
IPV6_PREFIX=""     # first four groups of the /64, e.g. 2001:db8:1:2
PUBLIC_HOST=""     # host written to the proxy list
LOCAL_IPV4=""      # local source IPv4, used by --ipv4-fallback
ROTATE_EVERY=""    # minutes between automatic IPv6 rotations, 0 = disabled
FIREWALL="none"    # firewalld | ufw | iptables | none
ASSUME_YES=0
LIST_URL=0

# Runtime state
PKG_MANAGER=""
PACKAGES_INSTALLED=0
HAS_TTY=0
TMP_DIR=""
ALNUM_POOL=""
HEX_POOL=""
declare -A USED_IPV6=()
declare -A USED_USERS=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s ✓ %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Report the failing command when "set -e" aborts the script.
on_error() {
  local status=$? line=$1 cmd=${2%%$'\n'*}   # first line only (heredocs are long)
  printf '%sERROR:%s command failed (exit %d) at line %d: %s\n' \
    "$C_RED" "$C_RESET" "$status" "$line" "$cmd" >&2
}

cleanup() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Interactive input
#
# Prompts read from /dev/tty, so they also work when the script itself is
# piped in ("curl ... | bash" or "bash <(curl ...)"). With --yes, or when no
# terminal is available, defaults are used without asking.
# ---------------------------------------------------------------------------

detect_tty() {
  if (: </dev/tty) 2>/dev/null; then
    HAS_TTY=1
  fi
}

is_interactive() {
  (( HAS_TTY == 1 && ASSUME_YES == 0 ))
}

# ask VAR "Question" "default" [validator]
# Stores the answer in VAR. Re-asks while the optional validator rejects it.
ask() {
  local __var=$1 __question=$2 __default=${3-} __validator=${4-} __reply

  while true; do
    if is_interactive; then
      if [[ -n $__default ]]; then
        read -r -p "${__question} [${__default}]: " __reply </dev/tty || __reply=""
      else
        read -r -p "${__question}: " __reply </dev/tty || __reply=""
      fi
      __reply=${__reply:-$__default}
    else
      __reply=$__default
    fi

    if [[ -z $__validator ]] || "$__validator" "$__reply"; then
      printf -v "$__var" '%s' "$__reply"
      return 0
    fi

    is_interactive || die "Invalid value '${__reply}' for: ${__question}"
    warn "Invalid value '${__reply}', please try again."
  done
}

# confirm "Question" - returns 0 when the user answers yes.
confirm() {
  local reply
  if (( ASSUME_YES == 1 )); then
    return 0
  fi
  (( HAS_TTY == 1 )) || die "Confirmation needed but no terminal is available. Re-run with --yes."
  read -r -p "$1 [y/N]: " reply </dev/tty || return 1
  [[ $reply =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ---------------------------------------------------------------------------
# Randomness
#
# Random data is read from /dev/urandom in blocks and kept in a pool, so that
# generating thousands of credentials does not spawn thousands of processes.
# Results are returned through a variable name (printf -v) because a
# "$(...)" subshell would throw away the updated pool.
# ---------------------------------------------------------------------------

# rand_alnum VAR LEN - LEN random characters from [A-Za-z0-9].
rand_alnum() {
  local len=$2
  while (( ${#ALNUM_POOL} < len )); do
    ALNUM_POOL+=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
  done
  printf -v "$1" '%s' "${ALNUM_POOL:0:len}"
  ALNUM_POOL=${ALNUM_POOL:len}
}

# rand_hex VAR LEN - LEN random lowercase hex digits.
rand_hex() {
  local len=$2
  while (( ${#HEX_POOL} < len )); do
    HEX_POOL+=$(od -An -v -tx1 -N4096 /dev/urandom | tr -d ' \n')
  done
  printf -v "$1" '%s' "${HEX_POOL:0:len}"
  HEX_POOL=${HEX_POOL:len}
}

# next_ipv6 VAR - a random, not yet used address inside IPV6_PREFIX::/64.
next_ipv6() {
  local h addr
  while true; do
    rand_hex h 16
    # Skip tiny suffixes like ::1 - they are usually the server's own address.
    if [[ ${h:0:12} == "000000000000" ]]; then
      continue
    fi
    printf -v addr '%s:%x:%x:%x:%x' "$IPV6_PREFIX" \
      "0x${h:0:4}" "0x${h:4:4}" "0x${h:8:4}" "0x${h:12:4}"
    if [[ -z ${USED_IPV6[$addr]+x} ]]; then
      USED_IPV6[$addr]=1
      printf -v "$1" '%s' "$addr"
      return 0
    fi
  done
}

# next_username VAR - a random, not yet used username such as "usrA1b2C3".
next_username() {
  local suffix
  while true; do
    rand_alnum suffix 6
    if [[ -z ${USED_USERS[usr$suffix]+x} ]]; then
      USED_USERS[usr$suffix]=1
      printf -v "$1" 'usr%s' "$suffix"
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# IPv6 helpers
# ---------------------------------------------------------------------------

# expand_ipv6 VAR ADDRESS - expand "::" so the address has all 8 groups.
# Example: 2001:db8::1 -> 2001:db8:0:0:0:0:0:1
expand_ipv6() {
  local addr=$2 head tail group i missing=0
  local -a head_groups=() tail_groups=() out=()

  [[ $addr =~ ^[0-9A-Fa-f:]+$ ]] || return 1

  if [[ $addr == *::* ]]; then
    [[ $addr != *::*::* ]] || return 1
    head=${addr%%::*}
    tail=${addr#*::}
    if [[ -n $head ]]; then IFS=: read -ra head_groups <<<"$head"; fi
    if [[ -n $tail ]]; then IFS=: read -ra tail_groups <<<"$tail"; fi
    missing=$(( 8 - ${#head_groups[@]} - ${#tail_groups[@]} ))
    (( missing >= 1 )) || return 1
  else
    IFS=: read -ra head_groups <<<"$addr"
    (( ${#head_groups[@]} == 8 )) || return 1
  fi

  for group in "${head_groups[@]}"; do
    [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    out+=("$group")
  done
  for (( i = 0; i < missing; i++ )); do
    out+=("0")
  done
  for group in "${tail_groups[@]}"; do
    [[ $group =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    out+=("$group")
  done

  local IFS=:
  printf -v "$1" '%s' "${out[*]}"
}

# normalize_ipv6_prefix VAR INPUT - turn "2001:db8:1:2", "2001:db8:1:2::/64"
# or any address inside the subnet into the /64 prefix "2001:db8:1:2".
normalize_ipv6_prefix() {
  local input=${2%%/*} full colons
  local -a groups=()

  colons=${input//[^:]/}
  # Exactly four groups without "::" is already a prefix, make it parseable.
  if [[ $input != *::* && ${#colons} -eq 3 ]]; then
    input+="::"
  fi

  expand_ipv6 full "$input" || return 1
  IFS=: read -ra groups <<<"$full"
  printf -v "$1" '%x:%x:%x:%x' "0x${groups[0]}" "0x${groups[1]}" "0x${groups[2]}" "0x${groups[3]}"
}

# detect_ipv6_prefix - find a global IPv6 /64 (or larger) on IFACE and store
# its first four groups in IPV6_PREFIX. Returns 1 if there is none.
detect_ipv6_prefix() {
  local cidrs cidr addr plen prefix
  cidrs=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}') || true

  for cidr in $cidrs; do
    addr=${cidr%/*}
    plen=${cidr#*/}
    if ! [[ $plen =~ ^[0-9]+$ ]] || (( plen > 64 )); then
      continue
    fi
    # Skip unique-local addresses (fc00::/7): they are not reachable from the internet.
    case ${addr,,} in fc*|fd*) continue ;; esac
    if normalize_ipv6_prefix prefix "$addr"; then
      IPV6_PREFIX=$prefix
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Validators (return 0 when the value is valid)
# ---------------------------------------------------------------------------

is_uint()        { [[ $1 =~ ^[0-9]+$ ]]; }
is_count()       { is_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 64512 )); }
is_port()        { is_uint "$1" && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
is_proxy_type()  { [[ $1 == http || $1 == socks5 || $1 == both ]]; }
is_auth_mode()   { [[ $1 == random || $1 == single || $1 == none ]]; }
is_egress_mode() { [[ $1 == ipv6 || $1 == ipv4 ]]; }
# Credentials are limited to URL-safe characters, so they never break the
# "host:port:user:pass" or "scheme://user:pass@host:port" output formats.
is_credential()  { [[ $1 =~ ^[A-Za-z0-9._~-]{1,64}$ ]]; }

is_ipv4() {
  local IFS=. octet
  local -a octets=()
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -ra octets <<<"$1"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

# One IPv4/IPv6 address with an optional CIDR suffix.
is_ip_or_cidr() {
  local addr=${1%/*} mask="" full
  if [[ $1 == */* ]]; then
    mask=${1#*/}
    is_uint "$mask" || return 1
  fi
  if is_ipv4 "$addr"; then
    [[ -z $mask ]] || (( 10#$mask <= 32 ))
  elif expand_ipv6 full "$addr"; then
    [[ -z $mask ]] || (( 10#$mask <= 128 ))
  else
    return 1
  fi
}

# Comma-separated list of addresses/CIDRs. An empty list means "anyone".
is_ip_list() {
  local item
  local -a items=()
  [[ -z $1 ]] && return 0
  IFS=, read -ra items <<<"$1"
  (( ${#items[@]} > 0 )) || return 1
  for item in "${items[@]}"; do
    is_ip_or_cidr "$item" || return 1
  done
}

# ---------------------------------------------------------------------------
# Usage and argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${C_BOLD}ipv6.sh ${SCRIPT_VERSION}${C_RESET} - create many HTTP / SOCKS5 proxies with 3proxy.

Usage:
  ipv6.sh [install] [options]   Install 3proxy and create proxies (default)
  ipv6.sh list [--url]          Print the proxy list
  ipv6.sh rotate                Give every proxy a new random IPv6 address
  ipv6.sh uninstall [--yes]     Remove proxies, service and all generated files

After installation the script is available as "${APP_NAME}", e.g. "${APP_NAME} list".

Install options (anything not given is asked interactively):
  -c, --count N          Number of proxies (default ${DEFAULT_COUNT})
  -t, --type TYPE        http | socks5 | both (default ${DEFAULT_TYPE})
                         "both" accepts HTTP and SOCKS5 on the same port
  -a, --auth MODE        random | single | none (default ${DEFAULT_AUTH})
                           random - unique username/password per proxy
                           single - one username/password for all proxies
                           none   - no password (use --allow-ip!)
  -u, --user NAME        Username for "--auth single" (random if omitted)
  -p, --pass PASS        Password for "--auth single" (random if omitted)
  -s, --start-port N     First port; proxies use N .. N+count-1 (default ${DEFAULT_START_PORT})
  -m, --mode MODE        ipv6 - every proxy gets its own random IPv6 (default)
                         ipv4 - all proxies use the server's IPv4 address
      --allow-ip LIST    Comma-separated client IPs/CIDRs allowed to connect
                         (default: any). Example: 203.0.113.7,198.51.100.0/24
      --ipv4-fallback    ipv6 mode: reach IPv4-only sites through the shared IPv4
      --iface NAME       Network interface (default: interface of the default route)
      --prefix PREFIX    IPv6 /64 prefix, e.g. 2001:db8:1:2 (default: detected)
      --host HOST        Host or IP written to the proxy list (default: public IPv4)
      --rotate-every MIN Rotate IPv6 addresses automatically every MIN minutes
  -y, --yes              Do not ask anything, use defaults for missing values
  -h, --help             Show this help
  -v, --version          Show the script version

Examples:
  ipv6.sh -c 500 -t socks5 -a random -y
  ipv6.sh -c 50 -t http -a single -u alice -p S3cret -y
  ipv6.sh -c 10 -t both -a none --allow-ip 203.0.113.7 -y
  ipv6.sh -c 1 -t both -m ipv4 -y
  ipv6.sh -c 200 -t socks5 --rotate-every 60 -y
EOF
}

# need_value OPTION VALUE - make sure an option received an argument.
need_value() {
  [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "Option $1 requires a value."
}

parse_args() {
  local opt value
  while (( $# > 0 )); do
    opt=$1
    # Support "--option=value" as well as "--option value".
    if [[ $opt == --*=* ]]; then
      value=${opt#*=}
      opt=${opt%%=*}
      shift
      set -- "$opt" "$value" "$@"
    fi

    case $1 in
      -c|--count)        need_value "$@"; COUNT=$2; shift 2 ;;
      -t|--type)         need_value "$@"; PROXY_TYPE=${2,,}; shift 2 ;;
      -a|--auth)         need_value "$@"; AUTH_MODE=${2,,}; shift 2 ;;
      -u|--user)         need_value "$@"; PROXY_USER=$2; shift 2 ;;
      -p|--pass)         need_value "$@"; PROXY_PASS=$2; shift 2 ;;
      -s|--start-port)   need_value "$@"; START_PORT=$2; shift 2 ;;
      -m|--mode)         need_value "$@"; EGRESS_MODE=${2,,}; shift 2 ;;
      --allow-ip)        [[ $# -ge 2 ]] || die "Option $1 requires a value."
                         ALLOW_IPS=${2// /}; ALLOW_IPS_SET=1; shift 2 ;;
      --ipv4-fallback)   IPV4_FALLBACK=1; shift ;;
      --iface)           need_value "$@"; IFACE=$2; shift 2 ;;
      --prefix)          need_value "$@"; IPV6_PREFIX=$2; shift 2 ;;
      --host)            need_value "$@"; PUBLIC_HOST=$2; shift 2 ;;
      --rotate-every)    need_value "$@"; ROTATE_EVERY=$2; shift 2 ;;
      --url)             LIST_URL=1; shift ;;
      -y|--yes)          ASSUME_YES=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      -v|--version)      echo "$SCRIPT_VERSION"; exit 0 ;;
      *)                 die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# System detection and preparation
# ---------------------------------------------------------------------------

require_root() {
  (( EUID == 0 )) || die "Please run as root (for example: sudo bash ipv6.sh)."
}

require_systemd() {
  [[ -d /run/systemd/system ]] || die "systemd is required but is not running on this system."
}

# Pick the package manager from /etc/os-release.
detect_os() {
  local ids
  [[ -r /etc/os-release ]] || die "Cannot detect the OS: /etc/os-release is missing."
  # shellcheck source=/dev/null
  ids=$(. /etc/os-release && echo " ${ID:-} ${ID_LIKE:-} ")

  case $ids in
    *" debian "*|*" ubuntu "*)
      PKG_MANAGER=apt ;;
    *" rhel "*|*" centos "*|*" fedora "*)
      if command -v dnf >/dev/null 2>&1; then PKG_MANAGER=dnf; else PKG_MANAGER=yum; fi ;;
    *)
      die "Unsupported OS (${ids// /}). Supported: Debian, Ubuntu, RHEL-based, Fedora." ;;
  esac
}

install_packages() {
  local -a pkgs=()
  (( PACKAGES_INSTALLED == 0 )) || return 0
  info "Installing required packages (${PKG_MANAGER})..."

  # curl is only added when missing: on RHEL 9 the preinstalled "curl-minimal"
  # conflicts with the full "curl" package.
  case $PKG_MANAGER in
    apt)
      pkgs=(build-essential ca-certificates iproute2 procps tar gzip)
      command -v curl >/dev/null 2>&1 || pkgs+=(curl)
      export DEBIAN_FRONTEND=noninteractive
      run_logged apt-get update
      run_logged apt-get install -y "${pkgs[@]}"
      ;;
    dnf|yum)
      pkgs=(gcc make ca-certificates iproute procps-ng tar gzip)
      command -v curl >/dev/null 2>&1 || pkgs+=(curl)
      run_logged "$PKG_MANAGER" install -y "${pkgs[@]}"
      ;;
  esac
  PACKAGES_INSTALLED=1
}

# run_logged CMD... - run quietly, but show the output if the command fails.
run_logged() {
  local log
  log=$(mktemp)
  if ! "$@" >"$log" 2>&1; then
    tail -n 30 "$log" >&2
    rm -f "$log"
    die "Command failed: $*"
  fi
  rm -f "$log"
}

# Interface of the default route (IPv6 first, then IPv4).
detect_iface() {
  local dev family
  for family in -6 -4; do
    dev=$(ip "$family" route show default 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}') || true
    if [[ -n $dev ]]; then
      IFACE=$dev
      return 0
    fi
  done
  return 1
}

# Public IPv4 of the server, as seen from the internet.
detect_public_ipv4() {
  local url ip
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv4 "$ip"; then
      printf -v "$1" '%s' "$ip"
      return 0
    fi
  done
  return 1
}

# Local source IPv4 used for outgoing connections (differs from the public
# one behind cloud NAT, e.g. on AWS or GCP).
detect_local_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true
}

check_ipv6_connectivity() {
  local addr
  addr=$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null) || true
  if [[ $addr == *:* ]]; then
    ok "IPv6 connectivity works (server address ${addr})."
  else
    warn "Could not reach the internet over IPv6. Proxies may not work until IPv6 is configured."
  fi
}

# Ports in the range that are already taken by some other program.
ports_in_use() {
  local last=$(( START_PORT + COUNT - 1 ))
  ss -Hltn "sport >= :${START_PORT} and sport <= :${last}" 2>/dev/null \
    | awk '{print $4}' || true
}

# ---------------------------------------------------------------------------
# Firewall
#
# Only a firewall that is actually active is touched. The whole port range is
# opened with a single rule instead of one rule per port.
# ---------------------------------------------------------------------------

detect_firewall() {
  local out
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
    return
  fi
  if command -v ufw >/dev/null 2>&1; then
    out=$(ufw status 2>/dev/null) || true
    if [[ $out == *"Status: active"* ]]; then
      echo ufw
      return
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    # Anything besides the default "accept everything" policy means iptables is in use.
    out=$(iptables -S INPUT 2>/dev/null) || true
    if [[ -n $out ]] && grep -qv '^-P INPUT ACCEPT$' <<<"$out"; then
      echo iptables
      return
    fi
  fi
  echo none
}

# iptables rule spec shared by the systemd unit and firewall_close.
iptables_rule() {
  echo "INPUT -p tcp --dport ${START_PORT}:$(( START_PORT + COUNT - 1 )) -j ACCEPT"
}

firewall_open() {
  local last=$(( START_PORT + COUNT - 1 ))
  case $FIREWALL in
    firewalld)
      firewall-cmd --permanent --add-port="${START_PORT}-${last}/tcp" >/dev/null
      firewall-cmd --reload >/dev/null
      ok "Opened ports ${START_PORT}-${last}/tcp in firewalld." ;;
    ufw)
      ufw allow "${START_PORT}:${last}/tcp" >/dev/null
      ok "Opened ports ${START_PORT}-${last}/tcp in ufw." ;;
    iptables)
      # The rule is (re)added by the systemd unit on every start.
      ok "Ports ${START_PORT}-${last}/tcp will be opened in iptables by the service." ;;
  esac
}

firewall_close() {
  local last=$(( START_PORT + COUNT - 1 ))
  case $FIREWALL in
    firewalld)
      firewall-cmd --permanent --remove-port="${START_PORT}-${last}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true ;;
    ufw)
      ufw delete allow "${START_PORT}:${last}/tcp" >/dev/null 2>&1 || true ;;
    iptables)
      # shellcheck disable=SC2046  # the rule must be split into words
      iptables -D $(iptables_rule) 2>/dev/null || true ;;
  esac
}

# ---------------------------------------------------------------------------
# 3proxy build
# ---------------------------------------------------------------------------

build_3proxy() {
  local src

  if [[ -x $BIN_3PROXY && -f $VERSION_FILE && $(<"$VERSION_FILE") == "$THREEPROXY_VERSION" ]]; then
    ok "3proxy ${THREEPROXY_VERSION} is already installed."
    return 0
  fi

  info "Downloading and building 3proxy ${THREEPROXY_VERSION} (takes a minute)..."
  TMP_DIR=$(mktemp -d)
  src="${TMP_DIR}/3proxy"
  mkdir -p "$src"

  curl -fsSL --retry 3 "$THREEPROXY_URL" -o "${TMP_DIR}/3proxy.tar.gz" \
    || die "Could not download ${THREEPROXY_URL}"
  tar -xzf "${TMP_DIR}/3proxy.tar.gz" -C "$src" --strip-components=1

  if ! make -C "$src" -f Makefile.Linux -j"$(nproc)" >"${TMP_DIR}/build.log" 2>&1; then
    tail -n 30 "${TMP_DIR}/build.log" >&2
    die "Building 3proxy failed (see the log above)."
  fi

  install -m 0755 "${src}/bin/3proxy" "$BIN_3PROXY"
  mkdir -p "$CONFIG_DIR"
  echo "$THREEPROXY_VERSION" >"$VERSION_FILE"
  ok "Installed 3proxy to ${BIN_3PROXY}."
}

# ---------------------------------------------------------------------------
# Generated files
# ---------------------------------------------------------------------------

# Kernel settings needed for many IPv6 addresses.
write_sysctl() {
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  cat >"$SYSCTL_FILE" <<'EOF'
# Generated by ipv6-proxy (ipv6.sh).
# Allow 3proxy to bind outgoing sockets to addresses that are not (yet) up.
net.ipv6.ip_nonlocal_bind = 1
# Older kernels cap the IPv6 route cache at 4096 entries, too few for many addresses.
net.ipv6.route.max_size = 409600
# Larger accept backlog for busy proxy ports.
net.core.somaxconn = 4096
EOF
  sysctl -e -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "Some sysctl settings could not be applied."
}

# Create proxies.db: one line per proxy with port, credentials and IPv6.
# Fields that do not apply are stored as "-" (a tab-separated file cannot
# hold empty fields when read with "read").
gen_proxy_db() {
  local port last user pass ip6
  last=$(( START_PORT + COUNT - 1 ))

  {
    for (( port = START_PORT; port <= last; port++ )); do
      case $AUTH_MODE in
        random) next_username user; rand_alnum pass 12 ;;
        single) user=$PROXY_USER; pass=$PROXY_PASS ;;
        none)   user="-"; pass="-" ;;
      esac
      if [[ $EGRESS_MODE == ipv6 ]]; then
        next_ipv6 ip6
      else
        ip6="-"
      fi
      printf '%s\t%s\t%s\t%s\n' "$port" "$user" "$pass" "$ip6"
    done
  } >"${DB_FILE}.tmp"
  chmod 600 "${DB_FILE}.tmp"
  mv "${DB_FILE}.tmp" "$DB_FILE"
}

# 3proxy service name for the selected proxy type.
threeproxy_service() {
  case $PROXY_TYPE in
    http)   echo "proxy" ;;
    socks5) echo "socks" ;;
    both)   echo "auto" ;;   # detects HTTP or SOCKS per connection
  esac
}

render_3proxy_cfg() {
  local service acl_src port user pass ip6
  local -a accounts=() args=()
  local -A seen=()
  service=$(threeproxy_service)
  acl_src=${ALLOW_IPS:-*}

  {
    cat <<EOF
# Generated by ${APP_NAME} (ipv6.sh ${SCRIPT_VERSION}) on $(date -u '+%Y-%m-%d %H:%M:%S UTC').
# Do not edit by hand: re-installing or "${APP_NAME} rotate" overwrites this file.
# Reference: man 3proxy.cfg

# DNS resolvers and cache used by 3proxy for client requests.
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
nscache6 65536

# Per-port connection limit and timeouts.
maxconn ${PROXY_MAXCONN}
timeouts 1 5 30 60 180 1800 15 60

# Drop root privileges once the configuration has been read.
setgid 65535
setuid 65535

# No request logging (privacy). Startup errors still go to the journal.
EOF

    # Accounts are taken from proxies.db (the single source of truth, also
    # for "rotate"). Several short "users" lines are used instead of one huge line.
    if [[ $AUTH_MODE != none ]]; then
      echo
      echo "# Accounts (username:CL:password, CL = cleartext)."
      while IFS=$'\t' read -r port user pass ip6; do
        # In "single" mode every line has the same account; list it once.
        [[ -z ${seen[$user]+x} ]] || continue
        seen[$user]=1
        accounts+=("${user}:CL:${pass}")
        if (( ${#accounts[@]} == USERS_PER_LINE )); then
          echo "users ${accounts[*]}"
          accounts=()
        fi
      done <"$DB_FILE"
      if (( ${#accounts[@]} > 0 )); then
        echo "users ${accounts[*]}"
      fi
    fi

    echo
    echo "# One block per proxy: authentication, access rule, listener, flush."
    while IFS=$'\t' read -r port user pass ip6; do
      echo

      args=("$service")
      # -a: anonymous HTTP proxy (no Forwarded / X-Forwarded-For headers).
      if [[ $service != socks ]]; then
        args+=(-a)
      fi
      # Outgoing address: unique IPv6, optionally falling back to the shared IPv4.
      if [[ $EGRESS_MODE == ipv6 ]]; then
        if (( IPV4_FALLBACK == 1 )); then
          args+=(-64 "-e${ip6}" "-e${LOCAL_IPV4}")
        else
          args+=(-6 "-e${ip6}")
        fi
        echo "# port ${port} -> ${ip6}"
      else
        echo "# port ${port}"
      fi
      args+=("-p${port}")

      if [[ $AUTH_MODE == none ]]; then
        echo "auth iponly"
        echo "allow * ${acl_src}"
      else
        echo "auth strong"
        echo "allow ${user} ${acl_src}"
      fi
      echo "${args[*]}"
      echo "flush"
    done <"$DB_FILE"
  } >"${CFG_FILE}.tmp"

  chmod 600 "${CFG_FILE}.tmp"
  mv "${CFG_FILE}.tmp" "$CFG_FILE"
}

# "ip -batch" files that add / remove all proxy addresses at once.
# "nodad" skips duplicate address detection, so the addresses are usable immediately.
render_ip_batches() {
  local port user pass ip6
  : >"$UP_BATCH"
  : >"$DOWN_BATCH"
  [[ $EGRESS_MODE == ipv6 ]] || return 0

  while IFS=$'\t' read -r port user pass ip6; do
    echo "addr add ${ip6}/64 dev ${IFACE} nodad" >>"$UP_BATCH"
    echo "addr del ${ip6}/64 dev ${IFACE}" >>"$DOWN_BATCH"
  done <"$DB_FILE"
}

# proxies.txt (host:port[:user:pass]) and proxies-url.txt (scheme://user:pass@host:port).
render_proxy_lists() {
  local port user pass ip6 scheme creds
  local -a schemes=()

  case $PROXY_TYPE in
    http)   schemes=(http) ;;
    socks5) schemes=(socks5) ;;
    both)   schemes=(http socks5) ;;
  esac

  while IFS=$'\t' read -r port user pass ip6; do
    if [[ $user == "-" ]]; then
      echo "${PUBLIC_HOST}:${port}"
    else
      echo "${PUBLIC_HOST}:${port}:${user}:${pass}"
    fi
  done <"$DB_FILE" >"$LIST_FILE"

  for scheme in "${schemes[@]}"; do
    while IFS=$'\t' read -r port user pass ip6; do
      creds=""
      [[ $user == "-" ]] || creds="${user}:${pass}@"
      echo "${scheme}://${creds}${PUBLIC_HOST}:${port}"
    done <"$DB_FILE"
  done >"$URL_LIST_FILE"

  chmod 600 "$LIST_FILE" "$URL_LIST_FILE"
}

render_all() {
  render_3proxy_cfg
  render_ip_batches
  render_proxy_lists
}

# settings.env keeps the chosen options for list / rotate / uninstall.
save_settings() {
  local var
  {
    echo "# Generated by ${APP_NAME} (ipv6.sh ${SCRIPT_VERSION}). Used by list, rotate and uninstall."
    for var in COUNT PROXY_TYPE AUTH_MODE START_PORT EGRESS_MODE ALLOW_IPS IPV4_FALLBACK \
               IFACE IPV6_PREFIX PUBLIC_HOST LOCAL_IPV4 ROTATE_EVERY FIREWALL; do
      printf '%s=%q\n' "$var" "${!var}"
    done
  } >"$SETTINGS_FILE"
  chmod 600 "$SETTINGS_FILE"
}

load_settings() {
  [[ -f $SETTINGS_FILE ]] || die "No installation found (${SETTINGS_FILE} is missing)."
  # shellcheck source=/dev/null
  . "$SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------

write_units() {
  local ip_bin iptables_bin rule
  ip_bin=$(command -v ip)

  {
    cat <<EOF
# Generated by ${APP_NAME} (ipv6.sh ${SCRIPT_VERSION}).
[Unit]
Description=Multi proxy server (3proxy, ${PROXY_TYPE}, ${COUNT} ports)
Documentation=https://github.com/maksqi/multi-proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EOF
    if [[ $EGRESS_MODE == ipv6 ]]; then
      # "-" = keep going if some addresses already exist.
      echo "ExecStartPre=-${ip_bin} -force -batch ${UP_BATCH}"
    fi
    if [[ $FIREWALL == iptables ]]; then
      iptables_bin=$(command -v iptables)
      rule=$(iptables_rule)
      echo "ExecStartPre=-/bin/sh -c '${iptables_bin} -C ${rule} 2>/dev/null || ${iptables_bin} -I ${rule}'"
    fi
    cat <<EOF
ExecStart=${BIN_3PROXY} ${CFG_FILE}
EOF
    if [[ $EGRESS_MODE == ipv6 ]]; then
      echo "ExecStopPost=-${ip_bin} -force -batch ${DOWN_BATCH}"
    fi
    if [[ $FIREWALL == iptables ]]; then
      echo "ExecStopPost=-/bin/sh -c '${iptables_bin} -D ${rule} 2>/dev/null || true'"
    fi
    cat <<EOF
Restart=on-failure
RestartSec=5
# 3proxy uses one thread and a couple of file descriptors per connection.
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
  } >"$SERVICE_FILE"

  rm -f "$ROTATE_SERVICE_FILE" "$ROTATE_TIMER_FILE"
  if [[ $EGRESS_MODE == ipv6 ]] && (( 10#${ROTATE_EVERY:-0} > 0 )); then
    cat >"$ROTATE_SERVICE_FILE" <<EOF
# Generated by ${APP_NAME} (ipv6.sh ${SCRIPT_VERSION}).
[Unit]
Description=Rotate the IPv6 addresses of ${APP_NAME}

[Service]
Type=oneshot
ExecStart=${SELF_BIN} rotate --yes
EOF
    cat >"$ROTATE_TIMER_FILE" <<EOF
# Generated by ${APP_NAME} (ipv6.sh ${SCRIPT_VERSION}).
[Unit]
Description=Rotate the IPv6 addresses of ${APP_NAME} every ${ROTATE_EVERY} minutes

[Timer]
OnBootSec=${ROTATE_EVERY}min
OnUnitActiveSec=${ROTATE_EVERY}min

[Install]
WantedBy=timers.target
EOF
  fi
  systemctl daemon-reload
}

# Wait until 3proxy listens on every port (startup can take a few seconds
# with thousands of ports).
wait_for_listeners() {
  local last=$(( START_PORT + COUNT - 1 )) listening=0 i
  for (( i = 0; i < 30; i++ )); do
    listening=$(ss -Hltn "sport >= :${START_PORT} and sport <= :${last}" 2>/dev/null | wc -l) || listening=0
    if (( listening >= COUNT )); then
      ok "All ${COUNT} proxy ports are listening."
      return 0
    fi
    systemctl is-active --quiet "$APP_NAME" || break
    sleep 1
  done
  journalctl -u "$APP_NAME" -n 20 --no-pager >&2 || true
  die "3proxy is listening on ${listening} of ${COUNT} ports. See 'journalctl -u ${APP_NAME}'."
}

# Install a copy of this script as "ipv6-proxy" for later commands and the
# rotation timer. When the script was piped in there is no file to copy, so
# it is downloaded again.
install_self() {
  local src=${BASH_SOURCE[0]}
  if [[ -f $SELF_BIN && $src -ef $SELF_BIN ]]; then
    return 0
  fi
  if [[ -f $src ]]; then
    install -m 0755 "$src" "$SELF_BIN"
  elif curl -fsSL --retry 3 "$SCRIPT_URL" -o "${SELF_BIN}.tmp"; then
    chmod 0755 "${SELF_BIN}.tmp"
    mv "${SELF_BIN}.tmp" "$SELF_BIN"
  else
    rm -f "${SELF_BIN}.tmp"
    warn "Could not install the '${APP_NAME}' command; list/rotate/uninstall need this script."
  fi
}

# Stop a previous installation and undo its addresses and firewall rules.
teardown_existing() {
  [[ -f $SETTINGS_FILE ]] || return 0
  info "Stopping the previous installation..."
  systemctl disable --now "${APP_NAME}-rotate.timer" >/dev/null 2>&1 || true
  systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true
  # In a subshell, so the old settings do not overwrite the new options.
  (
    load_settings
    if [[ -s $DOWN_BATCH ]]; then
      ip -force -batch "$DOWN_BATCH" >/dev/null 2>&1 || true
    fi
    firewall_close
  )
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# Ask for every option that was not given on the command line.
collect_options() {
  local default_mode=ipv4 last

  if [[ -z $IFACE ]]; then
    detect_iface || die "Cannot detect the network interface. Use --iface."
  fi
  [[ -d /sys/class/net/$IFACE ]] || die "Network interface '${IFACE}' does not exist."

  # Outgoing address mode: ipv6 only makes sense with a /64 on the server.
  if [[ -n $IPV6_PREFIX ]]; then
    normalize_ipv6_prefix IPV6_PREFIX "$IPV6_PREFIX" || die "Invalid IPv6 prefix '${IPV6_PREFIX}'."
    default_mode=ipv6
  elif detect_ipv6_prefix; then
    default_mode=ipv6
  fi
  if [[ -z $EGRESS_MODE ]]; then
    if [[ $default_mode == ipv4 ]]; then
      warn "No global IPv6 /64 found on ${IFACE}; proxies will use the server IPv4 unless you pass --prefix."
    fi
    ask EGRESS_MODE "Outgoing IP mode (ipv6 = unique IPv6 per proxy, ipv4 = shared server IPv4)" \
      "$default_mode" is_egress_mode
  fi
  is_egress_mode "$EGRESS_MODE" || die "Invalid --mode '${EGRESS_MODE}' (use ipv6 or ipv4)."
  if [[ $EGRESS_MODE == ipv6 && -z $IPV6_PREFIX ]]; then
    die "No IPv6 /64 subnet found on ${IFACE}. Pass it with --prefix, or use --mode ipv4."
  fi

  [[ -n $PROXY_TYPE ]] || ask PROXY_TYPE "Proxy type (http / socks5 / both)" "$DEFAULT_TYPE" is_proxy_type
  is_proxy_type "$PROXY_TYPE" || die "Invalid --type '${PROXY_TYPE}' (use http, socks5 or both)."

  [[ -n $AUTH_MODE ]] || ask AUTH_MODE "Authentication (random = per proxy, single = one account, none)" \
    "$DEFAULT_AUTH" is_auth_mode
  is_auth_mode "$AUTH_MODE" || die "Invalid --auth '${AUTH_MODE}' (use random, single or none)."

  if [[ $AUTH_MODE == single ]]; then
    local random_user random_pass
    rand_alnum random_user 8
    rand_alnum random_pass 12
    [[ -n $PROXY_USER ]] || ask PROXY_USER "Username" "usr${random_user}" is_credential
    [[ -n $PROXY_PASS ]] || ask PROXY_PASS "Password" "$random_pass" is_credential
    is_credential "$PROXY_USER" || die "Invalid username: use 1-64 characters from A-Z a-z 0-9 . _ ~ -"
    is_credential "$PROXY_PASS" || die "Invalid password: use 1-64 characters from A-Z a-z 0-9 . _ ~ -"
  elif [[ -n $PROXY_USER || -n $PROXY_PASS ]]; then
    die "--user and --pass can only be used with --auth single."
  fi

  if (( ALLOW_IPS_SET == 0 )); then
    ask ALLOW_IPS "Allowed client IPs/CIDRs, comma-separated (empty = any)" "" is_ip_list
    ALLOW_IPS=${ALLOW_IPS// /}
  fi
  is_ip_list "$ALLOW_IPS" || die "Invalid --allow-ip list '${ALLOW_IPS}'."

  [[ -n $COUNT ]] || ask COUNT "How many proxies to create" "$DEFAULT_COUNT" is_count
  is_count "$COUNT" || die "Invalid --count '${COUNT}' (1-64512)."
  COUNT=$(( 10#$COUNT ))

  [[ -n $START_PORT ]] || ask START_PORT "First port" "$DEFAULT_START_PORT" is_port
  is_port "$START_PORT" || die "Invalid --start-port '${START_PORT}' (1024-65535)."
  START_PORT=$(( 10#$START_PORT ))
  last=$(( START_PORT + COUNT - 1 ))
  (( last <= 65535 )) || die "Ports ${START_PORT}-${last} exceed 65535. Lower --count or --start-port."
  warn_ephemeral_overlap "$last"

  if [[ $EGRESS_MODE == ipv6 ]]; then
    [[ -n $ROTATE_EVERY ]] || ask ROTATE_EVERY "Rotate IPv6 addresses every N minutes (0 = never)" "0" is_uint
  fi
  ROTATE_EVERY=${ROTATE_EVERY:-0}
  is_uint "$ROTATE_EVERY" || die "Invalid --rotate-every '${ROTATE_EVERY}' (minutes)."
  ROTATE_EVERY=$(( 10#$ROTATE_EVERY ))
  if (( ROTATE_EVERY > 0 )) && [[ $EGRESS_MODE != ipv6 ]]; then
    die "--rotate-every only works with --mode ipv6."
  fi
  if (( IPV4_FALLBACK == 1 )) && [[ $EGRESS_MODE != ipv6 ]]; then
    die "--ipv4-fallback only works with --mode ipv6."
  fi
}

# Proxy ports inside the kernel's ephemeral range can clash with outgoing connections.
warn_ephemeral_overlap() {
  local last=$1 low high
  read -r low high </proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || return 0
  if (( START_PORT <= high && last >= low )); then
    warn "Ports ${START_PORT}-${last} overlap the ephemeral port range ${low}-${high}; some ports may be busy."
  fi
}

print_plan() {
  local last=$(( START_PORT + COUNT - 1 )) type_text auth_text egress_text
  case $PROXY_TYPE in
    http)   type_text="HTTP/HTTPS" ;;
    socks5) type_text="SOCKS5" ;;
    both)   type_text="HTTP + SOCKS5 (auto-detected on each port)" ;;
  esac
  case $AUTH_MODE in
    random) auth_text="unique username/password per proxy" ;;
    single) auth_text="single account '${PROXY_USER}'" ;;
    none)   auth_text="none" ;;
  esac
  if [[ $EGRESS_MODE == ipv6 ]]; then
    egress_text="unique random IPv6 from ${IPV6_PREFIX}::/64 on ${IFACE}"
    (( IPV4_FALLBACK == 0 )) || egress_text+=" (IPv4 fallback)"
  else
    egress_text="shared server IPv4"
  fi

  echo
  echo "${C_BOLD}Proxy setup${C_RESET}"
  echo "  Type:        ${type_text}"
  echo "  Count:       ${COUNT} (ports ${START_PORT}-${last})"
  echo "  Auth:        ${auth_text}"
  echo "  Allowed IPs: ${ALLOW_IPS:-any}"
  echo "  Outgoing IP: ${egress_text}"
  echo "  List host:   ${PUBLIC_HOST}"
  if (( ROTATE_EVERY > 0 )); then
    echo "  Rotation:    every ${ROTATE_EVERY} minutes"
  fi
  echo
}

print_summary() {
  local shown=5
  echo
  echo "${C_GREEN}${C_BOLD}Proxies are ready!${C_RESET}"
  echo
  echo "  ${LIST_FILE}       host:port$( [[ $AUTH_MODE == none ]] || echo ':user:pass' )"
  echo "  ${URL_LIST_FILE}   scheme://$( [[ $AUTH_MODE == none ]] || echo 'user:pass@' )host:port"
  echo
  echo "First proxies:"
  head -n "$shown" "$URL_LIST_FILE" | sed 's/^/  /'
  if (( COUNT > shown )); then
    echo "  ... and $(( COUNT - shown )) more"
  fi
  echo
  echo "Manage:"
  echo "  ${APP_NAME} list [--url]       print the proxy list"
  if [[ $EGRESS_MODE == ipv6 ]]; then
    echo "  ${APP_NAME} rotate             new random IPv6 for every proxy"
  fi
  echo "  ${APP_NAME} uninstall          remove everything"
  echo "  systemctl status ${APP_NAME}   service status"
  if [[ $EGRESS_MODE == ipv6 && $PROXY_TYPE != http ]]; then
    echo
    echo "Tip: use socks5h:// (remote DNS) in clients. With plain socks5:// the client resolves"
    echo "     names itself and may send an IPv4 address, which an IPv6-only proxy cannot reach."
  fi
}

cmd_install() {
  local busy

  require_root
  require_systemd
  detect_os
  # "ip" and "curl" are needed for detection before the questions are asked.
  if ! command -v ip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    install_packages
  fi

  collect_options

  if [[ -z $PUBLIC_HOST ]]; then
    detect_public_ipv4 PUBLIC_HOST || PUBLIC_HOST=$(detect_local_ipv4)
    [[ -n $PUBLIC_HOST ]] || die "Cannot detect the server IPv4. Pass it with --host."
  fi
  LOCAL_IPV4=$(detect_local_ipv4)
  if (( IPV4_FALLBACK == 1 )) && [[ -z $LOCAL_IPV4 ]]; then
    die "--ipv4-fallback needs a local IPv4 address, none was found."
  fi

  print_plan

  if [[ $AUTH_MODE == none && -z $ALLOW_IPS ]]; then
    warn "Authentication is disabled and no --allow-ip is set: ANYONE on the internet can use"
    warn "these proxies. Open proxies are quickly found and abused (spam, attacks) in your name."
    confirm "Create open proxies anyway?" || die "Aborted."
  fi
  if [[ -f $SETTINGS_FILE ]]; then
    warn "An existing installation was found. Its proxies will be replaced."
  fi
  confirm "Continue?" || die "Aborted."

  install_packages
  build_3proxy
  teardown_existing

  busy=$(ports_in_use)
  [[ -z $busy ]] || die "These ports are already in use: $(echo "$busy" | tr '\n' ' ')"

  info "Generating ${COUNT} proxies..."
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [[ $EGRESS_MODE == ipv6 ]]; then
    write_sysctl
  fi
  FIREWALL=$(detect_firewall)
  gen_proxy_db
  render_all
  save_settings
  install_self
  write_units
  firewall_open

  info "Starting the ${APP_NAME} service..."
  systemctl enable --now "$APP_NAME" >/dev/null 2>&1 || {
    journalctl -u "$APP_NAME" -n 20 --no-pager >&2 || true
    die "The service failed to start."
  }
  if [[ -f $ROTATE_TIMER_FILE ]]; then
    systemctl enable --now "${APP_NAME}-rotate.timer" >/dev/null 2>&1
    ok "IPv6 rotation scheduled every ${ROTATE_EVERY} minutes."
  fi
  wait_for_listeners

  if [[ $EGRESS_MODE == ipv6 ]]; then
    check_ipv6_connectivity
  fi
  print_summary
}

cmd_list() {
  require_root
  [[ -f $LIST_FILE ]] || die "No proxies found. Run the installer first."
  if (( LIST_URL == 1 )); then
    cat "$URL_LIST_FILE"
  else
    cat "$LIST_FILE"
  fi
}

cmd_rotate() {
  local port user pass ip6 new_ip6

  require_root
  load_settings
  [[ $EGRESS_MODE == ipv6 ]] || die "Rotation only works in ipv6 mode."

  # Remember the current addresses, so no proxy gets its old address back.
  while IFS=$'\t' read -r port user pass ip6; do
    USED_IPV6[$ip6]=1
  done <"$DB_FILE"

  while IFS=$'\t' read -r port user pass ip6; do
    next_ipv6 new_ip6
    printf '%s\t%s\t%s\t%s\n' "$port" "$user" "$pass" "$new_ip6"
  done <"$DB_FILE" >"${DB_FILE}.new"
  chmod 600 "${DB_FILE}.new"

  # Stopping the service removes the old addresses (ExecStopPost); starting
  # it adds the new ones (ExecStartPre).
  info "Rotating ${COUNT} IPv6 addresses..."
  systemctl stop "$APP_NAME"
  mv "${DB_FILE}.new" "$DB_FILE"
  render_all
  systemctl start "$APP_NAME"
  wait_for_listeners
  ok "Every proxy now uses a new IPv6 address (ports and credentials unchanged)."
}

cmd_uninstall() {
  require_root
  if [[ ! -f $SETTINGS_FILE && ! -f $SERVICE_FILE ]]; then
    die "Nothing to uninstall: ${APP_NAME} is not installed."
  fi
  confirm "Remove all proxies, the ${APP_NAME} service and its files?" || die "Aborted."

  info "Stopping services..."
  systemctl disable --now "${APP_NAME}-rotate.timer" >/dev/null 2>&1 || true
  systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true

  if [[ -f $SETTINGS_FILE ]]; then
    load_settings
    if [[ -s $DOWN_BATCH ]]; then
      ip -force -batch "$DOWN_BATCH" >/dev/null 2>&1 || true
    fi
    firewall_close
  fi

  info "Removing files..."
  rm -f "$SERVICE_FILE" "$ROTATE_SERVICE_FILE" "$ROTATE_TIMER_FILE" "$SYSCTL_FILE"
  systemctl daemon-reload
  # Only remove the 3proxy binary if this script installed it.
  if [[ -f $VERSION_FILE ]]; then
    rm -f "$BIN_3PROXY"
  fi
  rm -rf "$CONFIG_DIR"
  rm -f "$SELF_BIN"
  ok "${APP_NAME} has been removed."
}

# ---------------------------------------------------------------------------
# Entry point. Everything above only defines functions, so a partially
# downloaded script never runs half of its steps.
# ---------------------------------------------------------------------------

main() {
  local cmd=install
  if (( $# > 0 )) && [[ $1 != -* ]]; then
    cmd=$1
    shift
  fi
  parse_args "$@"
  detect_tty

  case $cmd in
    install)   cmd_install ;;
    list)      cmd_list ;;
    rotate)    cmd_rotate ;;
    uninstall) cmd_uninstall ;;
    help)      usage ;;
    *)         die "Unknown command: ${cmd} (see --help)" ;;
  esac
}

main "$@"
