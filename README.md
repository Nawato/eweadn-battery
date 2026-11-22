# eweadn-battery

Linux battery and settings control for **EWEADN S9-series wireless mice** over
their 2.4 GHz receiver, with a **Noctalia bar widget and control panel**.

The mouse/receiver does not expose a standard HID battery usage or a
`power_supply` device, so UPower cannot see it. This project talks directly to
the vendor HID interface, using the same protocol as EWEADN's web driver.

- Battery percentage in the Noctalia bar
- Control panel: polling rate, DPI stage/value, and button remapping
- Charging state and a `?` marker when the last reading is stale
- Low-battery notification at 15 %
- Left-click the widget for the panel; right-click forces a refresh
- Polls every 30 seconds; starts with Noctalia
- No vendor software and no Bluetooth mode required

Writes are explicit: the helper dry-runs unless `--apply` is passed, saves a
JSON backup before every write, and verifies the result by reading it back.
Profile switching is read-only on the S9 (see below).

## Supported hardware

| Device | USB ID | Transport |
| --- | --- | --- |
| EWEADN S9 / S9 Pro 8K receiver | `372e:1026` | 2.4 GHz |
| EWEADN S9 Pro 1K receiver | `372e:103d` | 2.4 GHz |
| Other S9-family receivers | `372e:1033`, `372e:1055`, `372e:105e` | 2.4 GHz |
| EWEADN S9 Ultra cable | `372e:1027` | USB |

The protocol is confirmed on `372e:1026`, `372e:1027` and `372e:103d`. Other
receiver IDs are included because they share the same S9 protocol, but they
have not all been tested. Battery, polling, DPI, button writes and profile
reads were verified on `372e:1027` (cable) and `372e:1026` (receiver).

The bundled udev rule matches `372e:1026` (the 8K receiver) and `372e:1027`
(USB-cable mode). If you use a different receiver, add its ID from `lsusb` to
the rule as another `ID_MODEL_ID` line.

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

### Control panel

Left-click the bar widget to open the panel. It shows battery, polling, current
DPI, profile, and five button rows. Polling, DPI, and each button have their own
**Apply** button; nothing is written just by changing a selection.

**Profiles** are read-only on the S9. EWEADN's S9 SDK exposes the current/max
profile number and supports binding a button to Profile 1–4 or Profile Cycle,
but it has no direct "switch profile" command. Use the onboard profile button or
the button mapping controls. (The web driver's direct profile switch only works
on other mouse chipsets.)

## Usage

```sh
eweadn-battery                 # battery, human-readable
eweadn-battery --json          # battery, stable JSON
eweadn-battery config          # polling, DPI stages, buttons, profile
eweadn-battery config --json   # same as JSON
eweadn-battery backup          # save a config backup
```

Writes are dry-run by default. Add `--apply` to change the mouse:

```sh
eweadn-battery set-polling 8000 --apply
eweadn-battery set-dpi 1 1600 --apply
eweadn-battery set-button back dpi_loop --apply
```

`set-button` accepts:

`left`, `right`, `middle`, `back`, `forward`, `dpi_up`, `dpi_down`,
`dpi_loop`, `profile_1`…`profile_4`, `profile_cycle`,
`media_play_pause`, `media_next`, `media_prev`, `media_mute`,
`volume_up`, `volume_down`, `disabled`.

The Noctalia panel exposes the same operations with Apply buttons. Each write
saves a backup under `~/.local/state/eweadn-battery/backups/` and is verified by
reading the config back from the mouse.

Example battery JSON:

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

Settings use the same feature report with command/offset bytes:

| Operation | Command | Payload |
| --- | --- | --- |
| sensor info | `0x4F 0x40` | none |
| DPI table | `0x4F 0x41` | none |
| button table | `0x4F 0x00` | none |
| set polling | `0x35 0x01` | 1 byte, wireless low nibble / wired high nibble |
| set DPI | `0x3A 0x00` | stage/count, 16-bit DPI, RGB |
| set button | `0x30 <key-pos>` | type, code, times, gap |

The exact key-position values and DPI encoding come from
`@bytech/mouse-pix` 1.11.1.

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

**A write says “verification failed”** — the mouse did not store the value, or
it answered with a different setting. The pre-write JSON backup is printed in
the error; keep EWEADN's web driver handy to restore a value if needed. Move the
mouse to wake it before retrying.

## Development

```sh
python3 -m unittest discover -s tests -v
```

Layout:

```text
bin/eweadn-battery        HID helper and settings writer
noctalia/plugin.toml      Noctalia plugin manifest
noctalia/service.luau     30-second poller and low-battery notification
noctalia/widget.luau      bar widget
noctalia/panel.luau       polling/DPI/button control panel
udev/                     hidraw permission rule
tests/                    parser, planner and ioctl tests
```

## License

MIT. Not affiliated with EWEADN.
