# multi-proxy

[![ShellCheck](https://github.com/maksqi/multi-proxy/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/maksqi/multi-proxy/actions/workflows/shellcheck.yml)

One script that turns a Linux VPS into hundreds or thousands of **HTTP** and/or
**SOCKS5** proxies. Each proxy can leave the server from its **own random IPv6
address** taken from the server's `/64` subnet. It is powered by
[3proxy](https://github.com/3proxy/3proxy).

## Features

- **Proxy types:** `http`, `socks5`, or `both` (HTTP and SOCKS5 on the **same port**, detected automatically)
- **Authentication:**
  - `random`: a unique username and password per proxy
  - `single`: one account for all proxies
  - `none`: no password, optionally limited to whitelisted client IPs
- **Outgoing IP:**
  - `ipv6`: a unique random IPv6 address per proxy
  - `ipv4`: the server's IPv4 address, for servers without IPv6
- **IPv6 rotation** on demand (`ipv6-proxy rotate`) or on a timer (`--rotate-every 60`)
- **Client IP whitelist** (`--allow-ip`) that works with every auth mode
- Interactive questions, or fully non-interactive with flags (`-y`)
- Runs as a **systemd** service, survives reboots, and restarts on failure
- Opens the port range in **firewalld**, **ufw** or **iptables** if one is active
- Clean `uninstall` that removes everything it created

## Requirements

- A VPS with root access and systemd
- One of: **Ubuntu 20.04+**, **Debian 11+**, **AlmaLinux / Rocky Linux / RHEL / CentOS Stream 8+**, **Fedora**
- For `ipv6` mode: a routed or on-link **IPv6 /64** on the server (most providers include one: Vultr, Hetzner, Linode, OVH, …)

## Quick start

Run as root and answer the questions:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv6.sh)
```

Or download the script first:

```bash
curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv6.sh -o ipv6.sh
sudo bash ipv6.sh
```

When it finishes, the proxy list is in `/etc/ipv6-proxy/proxies.txt`.

## Examples

```bash
# 500 SOCKS5 proxies, each with its own username/password and IPv6
bash ipv6.sh -c 500 -t socks5 -a random -y

# 50 HTTP proxies sharing one account
bash ipv6.sh -c 50 -t http -a single -u alice -p S3cret -y

# 10 HTTP+SOCKS5 proxies without password, only usable from your IP
bash ipv6.sh -c 10 -t both -a none --allow-ip 203.0.113.7 -y

# One proxy on a server without IPv6
bash ipv6.sh -c 1 -t both -m ipv4 -y

# 200 SOCKS5 proxies that get new IPv6 addresses every hour
bash ipv6.sh -c 200 -t socks5 --rotate-every 60 -y
```

## Options

Any install option you leave out is asked interactively. With `-y`, the default is used instead.

| Option | Description | Default |
|---|---|---|
| `-c, --count N` | Number of proxies | `100` |
| `-t, --type TYPE` | `http`, `socks5` or `both` (both protocols on each port) | `both` |
| `-a, --auth MODE` | `random`, `single` or `none` | `random` |
| `-u, --user NAME` | Username for `--auth single` | random |
| `-p, --pass PASS` | Password for `--auth single` | random |
| `-s, --start-port N` | First port; proxies use `N … N+count-1` | `10000` |
| `-m, --mode MODE` | `ipv6` (unique IPv6 per proxy) or `ipv4` (shared server IPv4) | `ipv6` if available |
| `--allow-ip LIST` | Comma-separated client IPs/CIDRs allowed to connect | anyone |
| `--ipv4-fallback` | In `ipv6` mode, reach IPv4-only sites through the shared IPv4 | off |
| `--iface NAME` | Network interface | default route |
| `--prefix PREFIX` | IPv6 /64 prefix, e.g. `2001:db8:1:2` | detected |
| `--host HOST` | Host or IP written to the proxy list | public IPv4 |
| `--rotate-every MIN` | Rotate IPv6 addresses every `MIN` minutes | off |
| `-y, --yes` | Non-interactive: don't ask, use defaults | |

Usernames and passwords may contain `A-Z a-z 0-9 . _ ~ -`, so they are safe in every output format.

## Commands

The installer saves a copy of itself as `ipv6-proxy`:

```bash
ipv6-proxy list          # host:port:user:pass
ipv6-proxy list --url    # socks5://user:pass@host:port
ipv6-proxy rotate        # new random IPv6 for every proxy (ports and passwords stay the same)
ipv6-proxy uninstall     # remove proxies, service, firewall rules and files
systemctl status ipv6-proxy
journalctl -u ipv6-proxy
```

## Output formats

`/etc/ipv6-proxy/proxies.txt`:

```text
203.0.113.10:10000:usrA1b2C3:9fK2mQ7xLp0Z
203.0.113.10:10001:usrD4e5F6:Qw3rTy8uIo1P
```

`/etc/ipv6-proxy/proxies-url.txt` (with `--type both`, every port appears once as `http://` and once as `socks5://`):

```text
http://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000
socks5://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000
```

With `--auth none`, the credentials are left out (`203.0.113.10:10000`).

Test a proxy:

```bash
curl -x socks5h://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000 https://api64.ipify.org
```

> Use `socks5h://` (remote DNS) rather than `socks5://`. With `socks5://` the client resolves
> hostnames itself and may send an IPv4 address, which an IPv6-only proxy cannot reach.

## How it works

1. Installs the build tools and compiles the pinned 3proxy release from its official source.
2. Generates a random IPv6 address inside your `/64` for every proxy, plus credentials if enabled.
3. Writes `/etc/ipv6-proxy/3proxy.cfg` with **one listener per port**. Each listener has its own access rule and its outgoing address (`-e<ipv6>`).
4. Creates the `ipv6-proxy` systemd service. On start it adds all addresses to the interface with a single `ip -batch` call, and on stop it removes them.
5. Opens the port range in the active firewall, starts the service, and checks that every port is listening.

Files:

| Path | Content |
|---|---|
| `/etc/ipv6-proxy/proxies.txt`, `proxies-url.txt` | Proxy lists |
| `/etc/ipv6-proxy/proxies.db` | Port, username, password, IPv6 for each proxy |
| `/etc/ipv6-proxy/3proxy.cfg` | Generated 3proxy configuration |
| `/etc/ipv6-proxy/settings.env` | Options used by `list`, `rotate` and `uninstall` |
| `/etc/systemd/system/ipv6-proxy.service` | Service unit (plus `ipv6-proxy-rotate.timer` if enabled) |
| `/usr/local/bin/3proxy`, `/usr/local/sbin/ipv6-proxy` | 3proxy binary and the management command |

## Security notes

- `--auth none` without `--allow-ip` creates an **open proxy**. Scanners find these within hours, and they get abused for spam and attacks, which are then traced to your server. The script warns you and asks for confirmation.
- Passwords are stored in plain text in `/etc/ipv6-proxy/` (readable by root only), because 3proxy needs them that way.
- 3proxy drops root privileges after start, and requests are not logged.
- Credentials are never uploaded anywhere. The proxy list stays on your server.

## Troubleshooting

- **No IPv6 /64 found.** Check `ip -6 addr`. If your provider routes a /64 to you that isn't configured on the interface, pass it with `--prefix 2001:db8:1:2`.
- **Proxies connect but sites don't load in ipv6 mode.** Check that the server itself has IPv6 with `curl -6 https://api64.ipify.org`. Some providers only route the first address unless you enable the full /64 in their panel.
- **IPv4-only websites fail.** These sites have no IPv6 address. Re-install with `--ipv4-fallback`; those sites will then see the server's IPv4.
- **The service doesn't start.** Run `journalctl -u ipv6-proxy -n 50`.
- **Ports aren't reachable from outside.** Check your provider's cloud firewall or security group, as well as the firewall on the server.

## Uninstall

```bash
ipv6-proxy uninstall
```

## Credits

Built on [3proxy](https://github.com/3proxy/3proxy) by Vladimir Dubrovin (3APA3A).
