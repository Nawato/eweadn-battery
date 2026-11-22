# eweadn-battery

Linux battery monitoring for **EWEADN S9-series wireless mice** over their
2.4 GHz receiver, with a **Noctalia bar widget**.

The mouse/receiver does not expose a standard HID battery usage or a
`power_supply` device, so UPower cannot see it. This project sends the same
read-only vendor feature report that EWEADN's web driver uses, then publishes
the result to Noctalia.

- Battery percentage in the Noctalia bar
- Charging state and a `?` marker when the last reading is stale
- Low-battery notification at 15 %
- Left-click the widget to refresh immediately
- Polls every 30 seconds; starts with Noctalia
- No vendor software and no Bluetooth mode required

## Supported hardware

| Device | USB ID | Transport |
| --- | --- | --- |
| EWEADN S9 / S9 Pro 8K receiver | `372e:1026` | 2.4 GHz |
| EWEADN S9 Pro 1K receiver | `372e:103d` | 2.4 GHz |
| Other S9-family receivers | `372e:1033`, `372e:1055`, `372e:105e` | 2.4 GHz |
| EWEADN S9 Ultra cable | `372e:1027` | USB |

The protocol is confirmed on `372e:1026` and `372e:103d`. Other receiver IDs
are included because they share the same S9 protocol, but they have not all
been tested.

The bundled udev rule matches `372e:1026` (the 8K receiver). If you use a
different receiver, replace `ID_MODEL_ID` in the rule with the ID reported by
`lsusb`.

## Requirements

- Linux with `hidraw`
- Python 3.10+
- [Noctalia](https://noctalia.dev) 5.6+ for the bar widget (the helper also
  works on its own)

## Install

```sh
git clone https://github.com/Nawato/eweadn-battery.git
cd eweadn-battery
./install.sh
```

The installer puts the helper in `~/.local/bin/eweadn-battery` and the plugin
in `~/.local/share/noctalia/plugins/eweadn-battery/`.

### udev rule

The receiver's vendor HID interface is root-only by default. Install the rule
once:

```sh
sudo install -Dm644 udev/70-eweadn-battery.rules /etc/udev/rules.d/70-eweadn-battery.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
```

If the permission does not appear, unplug and replug the receiver. Verify:

```sh
getfacl /dev/hidraw9    # node number may differ
eweadn-battery --json
```

The rule grants access only to the vendor interface (interface 02), not to the
mouse/keyboard HID nodes.

### Noctalia

Add the plugin and widget to `~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = [ "nawato/eweadn-battery" ]

[widget.mouse_battery]
type = "nawato/eweadn-battery:battery"
```

Then place `mouse_battery` in the bar where you want it, for example:

```toml
[bar.default]
end = [ "network", "mouse_battery", "volume", "session" ]
```

If `[plugins]` already exists, merge the entry into its `enabled` list. Validate
and reload:

```sh
noctalia config validate
noctalia msg config-reload
```

No separate autostart is needed: the plugin service is loaded with Noctalia,
and Noctalia is normally started by the compositor at login.

## Usage

```sh
eweadn-battery           # human-readable
eweadn-battery --json    # stable JSON for scripts
```

Example:

```json
{"percent":100,"charging":false,"status":100,"raw":"03 50 00 0b 00 01 64 21 07 02 30 75 04 a5 5a 00","ok":true,"path":"/dev/hidraw9","name":"Gaming Mouse 8K EWEADN S9","vendor":"372e","product":"1026","source":"2.4 GHz receiver"}
```

Force the Noctalia service to poll without waiting:

```sh
noctalia msg plugin nawato/eweadn-battery:monitor all refresh
```

Exit codes: `0` success, `2` receiver not found, `3` permission denied,
`4` no reply/asleep, `5` unexpected reply.

## How it works

The receiver exposes a 64-byte feature report on usage page `0xFF00`, report
ID `0x03`.

```text
request: 03 20 50 00 00 4F 81 00 ...              (64 bytes, report ID first)
reply:   03 50 00 0B 00 01 <level> <status> ... A5 5A
                           ^^^^^^^
                           byte 6: bits 0-6 = percent, bit 7 = charging
```

While charging, the firmware reports `0xE4` and the low bits are not a real
level, so the helper returns `"percent": null` and the widget displays
**Charging** instead of a fake 100 %.

The mouse sleeps when idle, so a poll can time out. The Noctalia widget keeps
the last value, marks it with `?`, and shows the last-update time and error in
its tooltip.

## Troubleshooting

**`permission denied`** — install the udev rule above and replug the receiver.
Check that the node has an ACL or `root:users` group access.

**`EWEADN receiver not found`** — check the receiver:

```sh
lsusb | grep -i 372e
```

**`no reply (mouse asleep or out of range)`** — move the mouse, then click the
widget or run the refresh command.

**Widget shows `--`** — Noctalia has not received a reading yet. Check
`~/.cache/noctalia/noctalia.log` and run `eweadn-battery --json`.

## Development

```sh
python3 -m unittest discover -s tests -v
```

Layout:

```text
bin/eweadn-battery        read-only HID helper
noctalia/plugin.toml      Noctalia plugin manifest
noctalia/service.luau     30-second poller and low-battery notification
noctalia/widget.luau      bar widget
udev/                     hidraw permission rule
tests/                    parser and ioctl tests
```

## License

MIT. Not affiliated with EWEADN.
