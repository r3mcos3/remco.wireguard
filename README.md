# WireGuard

WireGuard VPN status icon for the Omarchy bar, with a click-to-open details
panel: connection state, ping/packet-loss, throughput, IP address and
endpoint. If no `wg0` connection exists yet, the panel shows an in-panel
file browser to import a `.conf` instead.

## Dependencies

All of these ship with Omarchy itself, so there is nothing extra to
install:

- `nmcli` (`networkmanager`) — reads/toggles/imports the `wg0` connection.
  Listed in `omarchy-base.packages`, so every Omarchy install has it.
- `jq` — JSON glue between the shell scripts and the QML widget. Also
  listed in `omarchy-base.packages`.
- `ip` (`iproute2`) — interface state and IP address. A hard dependency of
  `networkmanager` itself.
- `ping` (`iputils`) — latency/packet-loss through the tunnel. Part of
  Arch's `base` package group.

No `wireguard-tools` (`wg`/`wg-quick`) and no file-dialog tool
(`zenity`/`kdialog`/etc.) are used — NetworkManager talks to the kernel
WireGuard module directly, and the "no profile yet" import browser is a
plain script + `Process`, not a native dialog.

The helper scripts in `scripts/` ship inside this repo and are invoked by
path relative to the plugin's own install directory
(`~/.config/omarchy/plugins/remco.wireguard/scripts/...`) — nothing is
expected to already exist elsewhere on your system. Every script output
that reaches the panel is size-capped (directory listings, nmcli error
text, endpoint) and every dynamic string rendered in the UI is displayed
as plain text, never interpreted as rich text/HTML.

## Privilege boundary

Every command runs as your own user through NetworkManager's D-Bus API
(`nmcli`) — no `sudo`. Whether creating or importing a connection profile
needs a polkit prompt depends on your system's polkit rules; on a default
Omarchy install the active local user can usually do this without one.

## Setup

Nothing to configure up front. If you don't have a `wg0` NetworkManager
connection yet, open the panel and use the file browser to pick a
WireGuard `.conf` — it gets imported and renamed to `wg0` automatically.

## Install

```sh
omarchy plugin add https://github.com/r3mcos3/remco.wireguard.git --enable
```

## Usage

Click the icon to open the details panel. Use the toggle to connect or
disconnect. If no profile exists yet, browse to and click a `.conf` file
to import it.

## Configure

```sh
omarchy bar move remco.wireguard --section right
```

## Remove

```sh
omarchy plugin remove remco.wireguard
```

Removing the plugin does not touch the `wg0` NetworkManager connection
itself — your VPN profile stays intact.
