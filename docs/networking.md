# Networking

The VM reaches the network through macOS, using NAT (Apple's vmnet), as WSL 2 does by default. All distributions share one network namespace, so they have the same IP address and one localhost between them.

## localhost

A server that listens on `localhost` in any distribution answers on `localhost` on macOS, over IPv4 and IPv6:

```console
$ python3 -m http.server 8000      # in a distribution
$ curl http://localhost:8000       # on macOS
```

msld watches the ports distributions listen on and opens the same port on macOS's `127.0.0.1` and `::1`. If macOS already uses that port, msld skips it and logs it in `~/Library/Application Support/msl/msld.log`.

Forwarded ports are reachable by every user on the Mac, as with WSL's localhost forwarding. To turn forwarding off, set `localhostForwarding = false` in `~/.mslconfig` ([Configuration](configuration.md)).

From a distribution, `host.internal` (added to its `/etc/hosts`) points at macOS, for reaching a server running on the Mac.

## DNS

Name lookups go through macOS's own resolver, so they behave as they do on macOS: VPNs with split DNS, custom resolvers in `/etc/resolver`, `.local` names and entries in macOS's `/etc/hosts` all work. Each distribution's `/etc/resolv.conf` points at a small resolver inside the VM, `10.255.255.254`, which forwards to macOS.

To use the VM network's DNS server instead, set `dnsTunneling = false`. A distribution that sets `generateResolvConf = false` in `/etc/wsl.conf` keeps its own `/etc/resolv.conf`.

## Hostname

A distribution's hostname is the macOS computer name, and msl generates its `/etc/hosts`. `[network] hostname` and `generateHosts` in `/etc/wsl.conf` override both, as in WSL.

## Not available

Mirrored networking (WSL's `networkingMode=mirrored`) isn't supported. The distributions reach the network only through NAT.
