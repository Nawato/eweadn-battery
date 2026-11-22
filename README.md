# eweadn-battery

[![CI](https://github.com/Nawato/eweadn-battery/actions/workflows/ci.yml/badge.svg)](https://github.com/Nawato/eweadn-battery/actions/workflows/ci.yml)

Linux battery and settings control for **EWEADN S9-series wireless mice** over
the 2.4 GHz receiver or USB cable, with a **Noctalia bar widget and control
panel**. Battery level is also read over Bluetooth through BlueZ.

The mouse/receiver does not expose a standard HID battery usage or a
`power_supply` device, so UPower cannot see it. This project talks directly to
the vendor HID interface, using the same protocol as EWEADN's web driver.

- Battery percentage in the Noctalia bar over 2.4 GHz, USB cable, or Bluetooth
- Control panel: polling rate, DPI stage/value, and button remapping over 2.4 GHz/USB
- Bluetooth battery monitoring through BlueZ (battery only)
- Charging state over 2.4 GHz/USB, and a `?` marker when the last reading is stale
- Low-battery notification at 15 %
- Left-click the widget for the panel; right-click forces a refresh
- Polls every 30 seconds; starts with Noctalia
- No vendor software; 2.4 GHz works without Bluetooth pairing

Writes are explicit: the helper dry-runs unless `--apply` is passed, saves a
JSON backup before every applied write, and verifies the changed settings by
reading them back from the mouse. `restore` writes a saved backup back
(polling, all DPI stages, the active stage, and the five buttons). Profile
switching is read-only on the S9 (see below).

## Supported hardware

| Device | USB ID | Transport | Status |
| --- | --- | --- | --- |
| EWEADN S9 / S9 Pro 8K receiver | `372e:1026` | 2.4 GHz | Hardware-verified |
| EWEADN S9 Ultra cable | `372e:1027` | USB | Hardware-verified |
| EWEADN S9 Pro 1K receiver | `372e:103d` | 2.4 GHz | Protocol confirmed |
| EWEADN S9 1K receiver | `372e:1033` | 2.4 GHz | Untested on hardware |
| EWEADN S9 Max receiver | `372e:1055` | 2.4 GHz | Untested on hardware |
| EWEADN S9 Ultra receiver | `372e:105e` | 2.4 GHz | Untested on hardware |

Battery, polling, DPI, button writes, and profile reads were verified on
`372e:1027` (cable) and `372e:1026` (receiver). `372e:103d` uses the same
confirmed protocol. The remaining IDs share the S9-family layout but are
untested on hardware.

The bundled udev rule covers all six IDs on vendor interface 02. For an
unlisted receiver, copy a matching line and change `ID_MODEL_ID` to the value
from `lsusb`.

### Connectivity support

| Link | Battery | Charging | Settings |
| --- | --- | --- | --- |
| 2.4 GHz receiver | Yes | Yes | Yes |
| USB cable | Yes | Yes | Yes |
| Bluetooth LE | Yes, via BlueZ | Unknown | No |

EWEADN's driver explicitly does not support settings over Bluetooth. In
Bluetooth mode the widget still shows the battery level, but the panel replaces
polling/DPI/button controls with a settings-unavailable message.

The helper only considers BlueZ devices whose name contains `EWEADN`. It reads
only the `Battery Percentage` property, so `eweadn-battery --json` over
Bluetooth includes `"charging_known": false`.

## Requirements

- Linux with `hidraw` for the 2.4 GHz receiver/cable
- Python 3.10+
- BlueZ and `bluetoothctl` for Bluetooth battery monitoring
- [Noctalia](https://noctalia.dev) 5.6+ (verified with 5.6.0) for the bar
  widget and panel. The manifest uses plugin API 52 and declares a `python3`
  dependency; the helper also works on its own.

## Install

```sh
git clone https://github.com/Nawato/eweadn-battery.git
cd eweadn-battery
./install.sh
```

The installer writes the helper to `~/.local/bin/eweadn-battery` and the plugin
to `${NOCTALIA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/noctalia/plugins/eweadn-battery/`.
It looks for the Noctalia config at
`${NOCTALIA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/noctalia/config.toml`.
`NOCTALIA_DATA_HOME` and `NOCTALIA_CONFIG_HOME` take precedence over the XDG
variables and are home roots, so the `noctalia/` component is still appended.

The installer never calls `sudo`. If the udev rule is missing or differs from
the bundled copy, it prints the exact commands to run. The comparison is
byte-for-byte (`cmp`). `EWEADN_UDEV_RULE` overrides the rule destination and is
provided for installer tests.

### udev rule

The receiver's vendor HID interface is root-only by default. Install the rule
once:

```sh
sudo install -Dm644 udev/70-eweadn-battery.rules /etc/udev/rules.d/70-eweadn-battery.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw
```

The rule matches only the vendor interface (`ID_USB_INTERFACE_NUM=02`) and uses
`MODE="0660"` with `GROUP="root"` and `TAG+="uaccess"`; it does not add a shared group.
`uaccess` grants an ACL to the active local seat user, while the node stays
root-only when no such ACL applies. The mouse/keyboard HID nodes keep their
normal permissions.

If the permission does not appear, unplug and replug the receiver. Verify:

```sh
getfacl /dev/hidraw9    # node number may differ; look for a user: ACL
eweadn-battery --json
```

If a unit enumerates its vendor interface differently, adjust its rule line.

### Bluetooth

No udev rule is needed for Bluetooth. Switch the mouse to Bluetooth mode and
pair it once:

```sh
bluetoothctl
power on
agent on
default-agent
scan on
# select "EWEADN S9" when it appears
pair XX:XX:XX:XX:XX:XX
trust XX:XX:XX:XX:XX:XX
connect XX:XX:XX:XX:XX:XX
scan off
exit
```

Verify BlueZ exposes a battery level:

```sh
bluetoothctl info XX:XX:XX:XX:XX:XX | grep -i 'Battery Percentage'
eweadn-battery --json
```

The helper tries connected BlueZ devices whose name contains `EWEADN` and reads
the first valid `Battery Percentage` property. It never sends vendor feature
reports over Bluetooth. Bluetooth is battery-only; settings still require the
receiver or cable, and charging state is unknown.

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

Left-click the bar widget to open the panel as a dropdown attached to the bar,
anchored near the widget. It shows the live battery state alongside polling,
current DPI, profile, and five button rows. Polling, DPI, and each button have
their own **Apply** button; nothing is written just by changing a selection.

Control rows share a 72/250/60 px label/select/Apply grid; the select sits in
a flexible, clipped slot in a narrow panel, keeping the Apply buttons aligned.
All mutating controls are disabled while a read or write is in flight. Reads
and writes are asynchronous: replies from a previous panel open are ignored,
and a refresh requested during a write runs afterwards. The header follows the
service's live battery state, updating when a newer reading arrives.

If the last reading was charging and the latest poll fails, the widget and
panel show **Charging?** with the error instead of claiming a live charge state.

**Profiles** are read-only on the S9. EWEADN's S9 SDK exposes the current/max
profile number and supports binding a button to Profile 1–4 or Profile Cycle,
but it has no direct "switch profile" command. Use the onboard profile button or
the button mapping controls. (The web driver's direct profile switch only works
on other mouse chipsets.)

Over Bluetooth the panel shows the battery and a settings-unavailable message;
polling, DPI, and button controls are hidden. Noctalia panels are layer-shell
surfaces, not toplevel windows. The dropdown is the native integration; a true
resizable window would need a separate GTK/Qt frontend (not included).

## Usage

```sh
eweadn-battery                    # battery, human-readable
eweadn-battery --json             # battery, stable JSON
eweadn-battery config             # polling, DPI stages, buttons, profile
eweadn-battery config --json      # same as JSON
eweadn-battery config --debug     # raw protocol frames; implies --json
eweadn-battery backup             # save a config backup
eweadn-battery backup --output PATH
eweadn-battery restore --backup PATH            # dry run
eweadn-battery restore --backup PATH --apply    # write the backup back
```

Writes are dry-run by default. Add `--apply` to change the mouse:

```sh
eweadn-battery set-polling 8000 --apply
eweadn-battery set-dpi 1 1600 --apply
eweadn-battery set-button back dpi_loop --apply
```

Supported polling rates are 125, 250, 500, 1000, 2000, 4000, and 8000 Hz.
`set-polling --wired` writes the wired nibble; otherwise the current link's
transport is used. `set-dpi` accepts `--stage-count 1-8` and `--color #RRGGBB`;
the value must be between 50 and the mouse's reported maximum, in steps of 50.

`set-button` accepts:

`left`, `right`, `middle`, `back`, `forward`, `dpi_up`, `dpi_down`,
`dpi_loop`, `profile_1`…`profile_4`, `profile_cycle`,
`media_play_pause`, `media_next`, `media_prev`, `media_mute`,
`volume_up`, `volume_down`, `disabled`.

Over Bluetooth, `config` returns the battery and
`"settings_available": false` when no USB receiver/cable is found; the `set-*`
commands require the 2.4 GHz receiver or the USB cable. A USB permission or
protocol error is reported rather than hidden behind a Bluetooth fallback.
`config` switches to this view only when no USB device is found; a present USB
device's other errors (including no reply) are reported instead.

Battery reads fall back to Bluetooth only when the USB receiver/cable is absent
or asleep/no reply. Permission and protocol errors from a present USB device do
not fall back. When a fallback is attempted and both links fail, the error
includes both causes.

### Writes and backups

Every applied write saves the current configuration first and reads it back
afterwards. Verification compares the exact fields the write intended to
change: the polling rate code for the active transport, the DPI stage value
and color plus stage count, and the button raw bytes. `restore` also verifies
the active DPI stage and uses the backup's saved wired/wireless polling
transport.

Backups are written atomically with mode `0600`. Automatic backups live in a
private `0700` directory under `$XDG_STATE_HOME/eweadn-battery/backups/`
(default: `~/.local/state/eweadn-battery/backups/`) and use timestamped names
that never replace an existing file; an explicit `--backup`/`--output` path is
replaced atomically. `restore --apply` also saves a safety backup of the
current configuration before writing.

If a write or read-back fails after a backup was saved, the error message and
JSON output include the backup path. Restore that file with:

```sh
eweadn-battery restore --backup PATH --apply
```

The Noctalia panel exposes the same polling, DPI, and button writes with Apply
buttons.

Example battery JSON:

```json
{
  "ok": true,
  "percent": 100,
  "charging": false,
  "status": 100,
  "raw": "03 50 00 0b 00 01 64 21 07 02 30 75 04 a5 5a 00",
  "path": "/dev/hidraw9",
  "name": "Gaming Mouse 8K EWEADN S9",
  "vendor": "372e",
  "product": "1026",
  "source": "2.4 GHz receiver",
  "battery": {"percent": 100, "charging": false, "raw": 100}
}
```

Force the Noctalia service to poll without waiting:

```sh
noctalia msg plugin nawato/eweadn-battery:monitor all refresh
```

Exit codes: `0` success, `1` validation/usage/IO, lock, backup or restore
error, `2` device not found, `3` permission denied, `4` no reply/asleep, `5`
unexpected or unverified reply.

## How it works

The helper enumerates `/sys/class/hidraw`, keeps only known `372e` products,
then parses each node's `device/report_descriptor`. A node is accepted only if
its descriptor declares a feature report on usage page `0xFF00` with report ID
`0x03`; it does not guess from VID/PID alone. Device names from the kernel or
BlueZ are sanitized before display.

The vendor HID interface exposes a 64-byte feature report on usage page
`0xFF00`, report ID `0x03`.

```text
request: 03 20 50 00 00 4F 81 00 ...              (64 bytes, report ID first)
reply:   03 50 00 0B 00 01 <battery> <profile> ... A5 5A
                           ^^^^^^^^^
                           reply byte 6: bits 0-6 = percent, bit 7 = charging
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

For battery reads, when USB access is missing or asleep, the helper asks
`bluetoothctl` for a connected EWEADN device and reads the BlueZ `Battery
Percentage` property. It does not send vendor feature reports over Bluetooth,
because EWEADN's driver does not support that. Bluetooth charging state is not
reported.

Vendor HID access is serialized by a `0600` lock file under
`$XDG_RUNTIME_DIR/eweadn-battery.lock`, or under
`$XDG_STATE_HOME/eweadn-battery/lock` when the runtime directory is unavailable
or untrusted. The lock wait is bounded at about 1.5 seconds, and device
enumeration is repeated after the lock is acquired.

The mouse sleeps when idle, so a poll can time out. The Noctalia widget keeps
the last value, marks it with `?`, and shows the last-update time and error in
its tooltip. A stale charging state is shown as `Charging?`.

## Troubleshooting

**`permission denied`** — install the udev rule above and replug the receiver.
Check `getfacl /dev/hidrawN`: the `uaccess` ACL should show your user with
`rw-` and a non-empty mask. If it is missing, reload udev and replug.

**`EWEADN receiver not found`** — check the receiver:

```sh
lsusb | grep -i 372e
```

**`no reply (mouse asleep or out of range)`** — move the mouse, then click the
widget or run the refresh command. A present USB link that returns a
permission or protocol error is reported directly instead of falling back to
Bluetooth.

**Bluetooth battery is missing** — check that the mouse is paired, connected,
named with `EWEADN`, and exposing Battery1:

```sh
bluetoothctl info XX:XX:XX:XX:XX:XX | grep -Ei 'Name|Connected|Battery'
```

If `Connected: yes` but no battery line appears, BlueZ is not exposing a
battery level; use the receiver or cable for battery telemetry. Charging state
is not available over Bluetooth.

**Widget shows `--`** — Noctalia has not received a reading yet. Check
`~/.cache/noctalia/noctalia.log` and run `eweadn-battery --json`.

**A write says "verification failed"** — the mouse did not store the value, or
it answered with a different setting. The pre-write JSON backup path is in the
error and in the JSON `backup` field; restore it with
`eweadn-battery restore --backup PATH --apply`. Move the mouse to wake it
before retrying.

## Development / CI

Run the same checks as CI:

```sh
python -m py_compile bin/eweadn-battery tests/test_eweadn_battery.py
python -m unittest discover -s tests -v
bash -n install.sh
shellcheck install.sh
udevadm verify udev/*.rules
for file in noctalia/*.luau; do
  luac5.4 -p "$file"
done
git diff --check
```

GitHub Actions runs CI on pushes and pull requests with Python 3.10, 3.12, and
3.14 on `ubuntu-latest`, installing `lua5.4` and `shellcheck`
(`.github/workflows/ci.yml`). Pushing a `v*` tag runs the tests, builds a
source archive named `eweadn-battery-<tag>.tar.gz`, and creates the GitHub
release with generated notes or uploads/replaces the archive on an existing
release (`.github/workflows/release.yml`).

Layout:

```text
bin/eweadn-battery        HID helper, CLI, backup and restore
noctalia/plugin.toml      Noctalia plugin manifest (API 52, python3)
noctalia/service.luau     30-second poller and low-battery notification
noctalia/widget.luau      bar widget
noctalia/panel.luau       attached polling/DPI/button control panel
udev/                     hidraw permission rule
tests/                    protocol, discovery, fallback, backup/restore and lock tests
.github/workflows/        CI and tag-triggered release
```

## License

MIT. Not affiliated with EWEADN.
