# multi-proxy

[![ShellCheck](https://github.com/maksqi/multi-proxy/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/maksqi/multi-proxy/actions/workflows/shellcheck.yml)

Turn a Linux VPS into hundreds or thousands of **HTTP** and/or **SOCKS5** proxies
with one command, powered by [3proxy](https://github.com/3proxy/3proxy).

| Script | What you get |
|---|---|
| [`ipv6.sh`](ipv6.sh) | Every proxy leaves the server from its **own random IPv6 address** from the server's `/64` |
| [`ipv4.sh`](ipv4.sh) | Proxies are spread over the server's **IPv4 addresses** (extra IPs or a subnet); with one IP they share it |

Both setups can run **at the same time** on one server, on different ports.

## Features

- **Proxy types:** `http`, `socks5`, or `both` (HTTP and SOCKS5 on the **same port**, detected automatically)
- **Authentication:**
  - `random`: a unique username and password per proxy
  - `single`: one account for all proxies
  - `none`: no password, optionally limited to whitelisted client IPs
- **Rotation:** give every proxy a new outgoing IP on demand (`multi-proxy rotate`) or on a timer (`--rotate-every 60`)
- **Client IP whitelist** (`--allow-ip`) that works with every auth mode
- Interactive questions, or fully non-interactive with flags (`-y`)
- Runs as a **systemd** service, survives reboots, and restarts on failure
- Opens the port range in **firewalld**, **ufw** or **iptables** if one is active
- Clean `uninstall` that removes everything it created

## Requirements

- A VPS with root access and systemd
- One of: **Ubuntu 20.04+**, **Debian 11+**, **AlmaLinux / Rocky Linux / RHEL / CentOS Stream 8+**, **Fedora**
- `ipv6.sh`: a routed or on-link **IPv6 /64** on the server (most providers include one: Vultr, Hetzner, Linode, OVH, …)
- `ipv4.sh`: one or more IPv4 addresses assigned to the server

## Quick start

Run as root and answer the questions:

```bash
# IPv6 proxies (unique IPv6 per proxy)
bash <(curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv6.sh)

# IPv4 proxies (spread over the server's IPv4 addresses)
bash <(curl -fsSL https://raw.githubusercontent.com/maksqi/multi-proxy/main/ipv4.sh)
```

Or clone the repository and run a script from it:

```bash
git clone https://github.com/maksqi/multi-proxy.git && cd multi-proxy
sudo bash ipv6.sh
```

When it finishes, the proxy list is in `/etc/multi-proxy/<ipv6|ipv4>/proxies.txt`.

## Examples

```bash
# 500 SOCKS5 proxies, each with its own username/password and IPv6
bash ipv6.sh -c 500 -t socks5 -a random -y

# 50 HTTP proxies sharing one account
bash ipv6.sh -c 50 -t http -a single -u alice -p S3cret -y

# 10 HTTP+SOCKS5 proxies without password, only usable from your IP
bash ipv6.sh -c 10 -t both -a none --allow-ip 203.0.113.7 -y

# 200 SOCKS5 proxies that get new IPv6 addresses every hour
bash ipv6.sh -c 200 -t socks5 --rotate-every 60 -y

# One proxy per IPv4 address of the server
bash ipv4.sh -t both -y

# Proxies on every address of an additional /29 subnet
bash ipv4.sh --ips 198.51.100.8/29 -t socks5 -y

# 20 proxies on a server with a single IPv4 (they share it)
bash ipv4.sh -c 20 -t http -y
```

## Options

Any install option you leave out is asked interactively. With `-y`, the default is used instead.

| Option | Description | Default |
|---|---|---|
| `-c, --count N` | Number of proxies | ipv6: `100`, ipv4: one per address |
| `-t, --type TYPE` | `http`, `socks5` or `both` (both protocols on each port) | `both` |
| `-a, --auth MODE` | `random`, `single` or `none` | `random` |
| `-u, --user NAME` | Username for `--auth single` | random |
| `-p, --pass PASS` | Password for `--auth single` | random |
| `-s, --start-port N` | First port; proxies use `N … N+count-1` | ipv6: `10000`, ipv4: `20000` |
| `--allow-ip LIST` | Comma-separated client IPs/CIDRs allowed to connect | anyone |
| `--iface NAME` | Network interface | default route |
| `--host HOST` | Host or IP written to the proxy list | public IPv4 |
| `--rotate-every MIN` | Rotate outgoing addresses every `MIN` minutes | off |
| `-y, --yes` | Non-interactive: don't ask, use defaults | |
| **ipv6 only** | | |
| `--prefix PREFIX` | IPv6 /64 prefix, e.g. `2001:db8:1:2` | detected |
| `--ipv4-fallback` | Reach IPv4-only sites through the shared server IPv4 | off |
| **ipv4 only** | | |
| `--ips LIST` | Outgoing IPv4 addresses and/or subnets (`/16`–`/32`), e.g. `203.0.113.10,198.51.100.8/29` | all IPv4 on the interface |

Usernames and passwords may contain `A-Z a-z 0-9 . _ ~ -`, so they are safe in every output format.

### How `ipv4.sh` uses your addresses

- Proxies are assigned to the addresses **round-robin**. With 5 addresses and 5 proxies, every proxy has its own IP. With 10 proxies, every IP serves two of them.
- `--ips` defaults to all IPv4 addresses already configured on the interface. You can also pass additional IPs or a subnet that your provider routes to the server. Addresses that aren't configured yet are added to the interface as `/32` when the service starts, and removed when it stops.
- In a subnet larger than `/31`, the network and broadcast addresses are skipped.
- Only list addresses that are **assigned to your server**. Using someone else's addresses breaks their traffic.

## Commands

The installer saves a management command as `multi-proxy`. Without `ipv6`/`ipv4` it works on every installed setup:

```bash
multi-proxy list [ipv6|ipv4]          # host:port:user:pass
multi-proxy list [ipv6|ipv4] --url    # socks5://user:pass@host:port
multi-proxy rotate [ipv6|ipv4]        # new outgoing IP for every proxy (ports and passwords stay the same)
multi-proxy uninstall [ipv6|ipv4]     # remove proxies, service, firewall rules and files
systemctl status multi-proxy-ipv6     # or multi-proxy-ipv4
journalctl -u multi-proxy-ipv6
```

What `rotate` does:
- **ipv6:** every proxy gets a fresh random IPv6 address.
- **ipv4:** every proxy moves to a different address from the pool. This needs at least two addresses.

`ipv6.sh` and `ipv4.sh` accept the same commands, e.g. `bash ipv4.sh uninstall`.

## Output formats

`/etc/multi-proxy/ipv6/proxies.txt`:

```text
203.0.113.10:10000:usrA1b2C3:9fK2mQ7xLp0Z
203.0.113.10:10001:usrD4e5F6:Qw3rTy8uIo1P
```

`/etc/multi-proxy/ipv6/proxies-url.txt` (with `--type both`, every port appears once as `http://` and once as `socks5://`):

```text
http://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000
socks5://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000
```

With `--auth none`, the credentials are left out (`203.0.113.10:10000`).

Test a proxy:

```bash
curl -x socks5h://usrA1b2C3:9fK2mQ7xLp0Z@203.0.113.10:10000 https://api64.ipify.org
```

> For IPv6 proxies, use `socks5h://` (remote DNS) rather than `socks5://`. With `socks5://`
> the client resolves hostnames itself and may send an IPv4 address, which an IPv6-only proxy
> cannot reach.

## How it works

1. Installs the build tools and compiles the pinned 3proxy release from its official source.
2. Picks an outgoing address for every proxy: a random IPv6 from your `/64`, or an IPv4 from the pool. It also generates credentials if enabled.
3. Writes `3proxy.cfg` with **one listener per port**. Each listener has its own access rule and outgoing address (`-e<ip>`).
4. Creates a systemd service. On start it adds the needed addresses to the interface with a single `ip -batch` call, and on stop it removes them.
5. Opens the port range in the active firewall, starts the service, and checks that every port is listening.

Files (one directory per setup):

| Path | Content |
|---|---|
| `/etc/multi-proxy/<mode>/proxies.txt`, `proxies-url.txt` | Proxy lists |
| `/etc/multi-proxy/<mode>/proxies.db` | Port, username, password and outgoing IP for each proxy |
| `/etc/multi-proxy/<mode>/3proxy.cfg` | Generated 3proxy configuration |
| `/etc/multi-proxy/<mode>/settings.env` | Options used by `list`, `rotate` and `uninstall` |
| `/etc/systemd/system/multi-proxy-<mode>.service` | Service unit (plus `multi-proxy-<mode>-rotate.timer` if enabled) |
| `/usr/local/bin/3proxy`, `/usr/local/sbin/multi-proxy` | 3proxy binary and the management command |

### Repository layout

| File | Purpose |
|---|---|
| `multi-proxy.sh` | The installer itself (all logic) |
| `ipv6.sh`, `ipv4.sh` | Short entry points that run `multi-proxy.sh` in the matching mode. When run through `curl`, they download `multi-proxy.sh` first. |

## Security notes

- `--auth none` without `--allow-ip` creates an **open proxy**. Scanners find these within hours, and they get abused for spam and attacks, which are then traced to your server. The script warns you and asks for confirmation.
- Passwords are stored in plain text in `/etc/multi-proxy/` (readable by root only), because 3proxy needs them that way.
- 3proxy drops root privileges after start, and requests are not logged.
- Credentials are never uploaded anywhere. The proxy list stays on your server.

## Troubleshooting

- **No IPv6 /64 found.** Check `ip -6 addr`. If your provider routes a /64 to you that isn't configured on the interface, pass it with `--prefix 2001:db8:1:2`.
- **Proxies connect but sites don't load in ipv6 mode.** Check that the server itself has IPv6 with `curl -6 https://api64.ipify.org`. Some providers only route the first address unless you enable the full /64 in their panel.
- **IPv4-only websites fail through IPv6 proxies.** These sites have no IPv6 address. Re-install with `--ipv4-fallback`; those sites will then see the server's IPv4.
- **Additional IPv4 addresses don't work.** Check that your provider has actually routed them to this server. Some providers also require them to be enabled in their panel.
- **The service doesn't start.** Run `journalctl -u multi-proxy-ipv6 -n 50` (or `-ipv4`).
- **Ports aren't reachable from outside.** Check your provider's cloud firewall or security group, as well as the firewall on the server.

## Uninstall

```bash
multi-proxy uninstall          # everything
multi-proxy uninstall ipv4     # only the IPv4 setup
```

## Credits

Built on [3proxy](https://github.com/3proxy/3proxy) by Vladimir Dubrovin (3APA3A).
