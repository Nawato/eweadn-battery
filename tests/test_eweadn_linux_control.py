from __future__ import annotations

import argparse
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin" / "eweadn-linux-control"

loader = importlib.machinery.SourceFileLoader("eweadn_linux_control", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


def capture_call(function, *args, **kwargs):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        result = function(*args, **kwargs)
    return result, out.getvalue(), err.getvalue()


def run_main(argv):
    return capture_call(module.main, argv)


def verified_config() -> dict:
    return {
        "device": {
            "name": "EWEADN S9",
            "source": "2.4 GHz receiver",
            "wired": False,
            "product": "1026",
            "vendor": "372e",
            "path": "/dev/hidraw9",
        },
        "polling": {
            "hz": 8000,
            "code": 4,
            "is_single_adjust": False,
            "max_report_code": 7,
        },
        "dpi": {
            "max_dpi": 26000,
            "current_stage": 1,
            "stage_count": 2,
            "stages": [
                {"index": 1, "dpi": 800, "color": "#ff0000"},
                {"index": 2, "dpi": 1600, "color": "#112233"},
            ],
        },
        "buttons": [
            {
                "index": index,
                "button": module.BUTTON_NAMES[index],
                "key_type": 1,
                "code1": index + 1,
                "code2": 1,
                "code3": 0,
                "action": "raw",
            }
            for index in range(5)
        ],
        "sensor": {
            "wired_rate_code": 0,
            "wireless_rate_code": 4,
            "is_single_adjust": False,
        },
        "battery": {"percent": 50, "charging": False, "raw": 50},
        "profile": {"current": 1, "max": 2, "sensor_current": 1},
    }


def backup_document() -> dict:
    return {
        "device": {"wired": False},
        "polling": {"hz": 8000, "code": 4, "is_single_adjust": False},
        "dpi": {
            "max_dpi": 26000,
            "current_stage": 2,
            "stage_count": 2,
            "stages": [
                {"index": 1, "dpi": 800, "color": "#FF0000"},
                {"index": 2, "dpi": 1600, "color": "#00FF00"},
            ],
        },
        "buttons": [
            {
                "index": index,
                "button": module.BUTTON_NAMES[index],
                "key_type": 1,
                "code1": index + 1,
                "code2": 1,
                "code3": 0,
            }
            for index in range(5)
        ],
    }


def descriptor(
    usage_page: int = 0xFF00, report_id: int = 0x03, main_tag: int = 0x0B
) -> bytes:
    main_prefix = {0x0B: 0xB1, 0x08: 0x81}[main_tag]
    return bytes(
        [
            0x06,
            usage_page & 0xFF,
            (usage_page >> 8) & 0xFF,
            0x09,
            0x02,
            0xA1,
            0x01,
            0x85,
            report_id,
            0x09,
            0x02,
            0x15,
            0x00,
            0x26,
            0xFF,
            0x00,
            0x75,
            0x08,
            0x95,
            0x40,
            main_prefix,
            0x02,
            0xC0,
        ]
    )


def make_hidraw(
    root: str,
    node: str,
    product: int,
    report_descriptor: bytes | None,
    name: str = "EWEADN S9",
    vendor: int = module.VID,
) -> None:
    device = pathlib.Path(root) / node / "device"
    device.mkdir(parents=True, exist_ok=True)
    (device / "uevent").write_text(
        f"HID_NAME={name}\nHID_ID=0003:{vendor:04X}:{product:04X}\n",
        encoding="utf-8",
    )
    if report_descriptor is not None:
        (device / "report_descriptor").write_bytes(report_descriptor)


def reply(status_byte: int) -> bytearray:
    frame = bytearray(64)
    frame[0] = 0x03
    frame[1] = 0x50
    frame[3] = 0x0B
    frame[6] = status_byte
    frame[13] = 0xA5
    frame[14] = 0x5A
    return frame


CONFIG = {
    "device": {"wired": False},
    "polling": {"is_single_adjust": False},
    "dpi": {
        "max_dpi": 26000,
        "current_stage": 1,
        "stage_count": 6,
        "stages": [
            {"index": 1, "dpi": 800, "color": "#ff0000"},
            {"index": 2, "dpi": 1600, "color": "#00ff00"},
        ],
    },
}


class ParseReplyTest(unittest.TestCase):
    def test_discharging_percentage(self) -> None:
        result = module.parse_basics(reply(0x35)[6:])
        self.assertEqual(result["battery"]["percent"], 53)
        self.assertFalse(result["battery"]["charging"])

    def test_low_battery(self) -> None:
        result = module.parse_basics(reply(0x0F)[6:])
        self.assertEqual(result["battery"]["percent"], 15)
        self.assertFalse(result["battery"]["charging"])

    def test_charging_sentinel_has_no_percentage(self) -> None:
        result = module.parse_basics(reply(0xE4)[6:])
        self.assertIsNone(result["battery"]["percent"])
        self.assertTrue(result["battery"]["charging"])

    def test_invalid_percentage(self) -> None:
        with self.assertRaises(module.ProtocolError):
            module.parse_basics(reply(0x7F)[6:])

    def test_ioctl_constants(self) -> None:
        self.assertEqual(module.HIDIOCSFEATURE, 0xC0404806)
        self.assertEqual(module.HIDIOCGFEATURE, 0xC0404807)

    def test_battery_request_matches_vendor_packet(self) -> None:
        request = module.build_request(0x4F, 0x81)
        self.assertEqual(request[:7], bytes.fromhex("03 20 50 00 00 4f 81"))

    def test_write_request_includes_length_and_checksum(self) -> None:
        request = module.build_request(0x35, 0x01, bytes([0x84]))
        self.assertEqual(request[:8], bytes.fromhex("03 0b 50 01 00 35 01 84"))
        self.assertEqual(request[1], sum(request[2:]) & 0xFF)

    def test_multipacket_encapsulation(self) -> None:
        request = module.build_request(0x4F, 0x42, encap=1)
        self.assertEqual(request[4], 1)
        self.assertEqual(request[6], 0x42)
        self.assertEqual(request[1], sum(request[2:]) & 0xFF)

    def test_read_chunks_concatenates(self) -> None:
        class FakeSession:
            def query(self, cmd, sub, encap=0, **_kwargs):
                return bytes([encap + 1]) + bytes([0xAA]) * 10, b""

        data = module.read_chunks(FakeSession(), 0x4F, 0x41, 40)
        self.assertEqual(len(data), 40)
        self.assertEqual(data[:2], bytes([1, 0xAA]))
        self.assertEqual(data[10], 0xAA)
        self.assertEqual(data[11], 0xAA)
        self.assertNotEqual(data[10:12], bytes([2, 0xAA]))


class ParseConfigTest(unittest.TestCase):
    def test_sensor_flags(self) -> None:
        data = bytes([17, 0x84, 0x36, 0, 2, 0, 60, 60, 60, 0])
        result = module.parse_sensor(data)
        self.assertTrue(result["is_single_adjust"])
        self.assertEqual(result["wireless_rate_code"], 4)
        self.assertEqual(result["wired_rate_code"], 0)
        self.assertEqual(result["current_stage"], 3)
        self.assertEqual(result["stage_count"], 6)

    def test_dpi_decode(self) -> None:
        self.assertEqual(module.decode_dpi(15, 26000), 800)
        self.assertEqual(module.decode_dpi(31, 26000), 1600)
        self.assertEqual(module.decode_dpi(32000, 26000), 32000)

    def test_dpi_stages(self) -> None:
        data = bytearray(58)
        data[1] = 15  # 800 DPI
        data[2] = 0
        data[3] = 31  # 1600 DPI
        data[4] = 0
        data[17:20] = bytes([255, 0, 0])
        data[20:23] = bytes([0, 255, 0])
        stages = module.parse_dpi(bytes(data), 26000)
        self.assertEqual(len(stages), 8)
        self.assertEqual(stages[0]["dpi"], 800)
        self.assertEqual(stages[1]["dpi"], 1600)
        self.assertEqual(stages[0]["color"], "#ff0000")
        self.assertEqual(stages[1]["color"], "#00ff00")

    def test_keymap(self) -> None:
        data = bytes(
            [
                1, 1, 1, 0,  # left click
                1, 2, 1, 0,  # right click
                5, 4, 1, 0,  # DPI loop
                6, 5, 0, 0,  # profile cycle
                0, 0, 0, 0,  # disabled
            ]
        )
        keys = module.parse_keys(data)
        self.assertEqual(keys[0]["action"], "left")
        self.assertEqual(keys[1]["action"], "right")
        self.assertEqual(keys[2]["action"], "dpi_loop")
        self.assertEqual(keys[3]["action"], "profile_cycle")
        self.assertEqual(keys[4]["action"], "disabled")


class ReadConfigTest(unittest.TestCase):
    class FakeSession:
        path = "/dev/hidraw9"
        name = "Gaming Mouse 8K EWEADN S9"
        vendor = 0x372E
        product = 0x1026
        closed = False

        @staticmethod
        def package(data: bytes, total: int) -> list[bytes]:
            chunks = [data[:11]]
            cursor = 11
            index = 1
            while len(chunks[0]) + sum(len(c) - 1 for c in chunks[1:]) < total:
                piece = data[cursor : cursor + 10]
                if not piece:
                    break
                chunks.append(bytes([index]) + piece)
                cursor += len(piece)
                index += 1
            return chunks

        def __init__(self):
            self.dpi = bytearray(64)
            for index, raw in enumerate([15, 31, 47, 63, 127, 255]):
                self.dpi[1 + index * 2] = raw & 0xFF
                self.dpi[2 + index * 2] = 0
                self.dpi[17 + index * 3 : 20 + index * 3] = bytes(
                    [index * 20, 255 - index * 20, 128]
                )
            self.dpi_chunks = self.package(bytes(self.dpi), 64)
            self.keys = bytes(
                [
                    1, 1, 1, 0,
                    1, 2, 1, 0,
                    1, 3, 1, 0,
                    1, 5, 1, 0,
                    1, 4, 1, 0,
                ]
                + [0] * 28
            )
            self.key_chunks = self.package(self.keys, 48)

        def query(self, cmd, sub, data=b"", encap=0, **_kwargs):
            if cmd == 0x4F and sub == 0x81:
                return bytes.fromhex("64 21 07 02 30 75 04 a5 5a 00 00"), b""
            if cmd == 0x4F and sub == 0x40:
                return bytes.fromhex("02 66 36 01 03 40 20 10 01 01 00"), b""
            if cmd == 0x4F and 0x41 <= sub <= 0x47:
                return (self.dpi_chunks[encap] if encap < len(self.dpi_chunks) else b""), b""
            if cmd == 0x4F and 0 <= sub <= 4:
                return (self.key_chunks[encap] if encap < len(self.key_chunks) else b""), b""
            raise AssertionError((cmd, sub, encap))

        def close(self):
            self.closed = True

    def test_full_config_parses_chunked_tables(self) -> None:
        fake = self.FakeSession()
        with mock.patch.object(module, "find_session", return_value=fake):
            config, _ = module.read_config()
        self.assertTrue(fake.closed)
        self.assertEqual(config["polling"]["hz"], 2000)
        self.assertEqual(config["dpi"]["current_stage"], 3)
        self.assertEqual(config["dpi"]["max_dpi"], 30000)
        self.assertEqual(len(config["dpi"]["stages"]), 6)
        self.assertEqual(config["dpi"]["stages"][0]["dpi"], 800)
        self.assertEqual(config["dpi"]["stages"][5]["dpi"], 12800)
        self.assertEqual(len(config["buttons"]), 5)
        self.assertEqual(config["buttons"][3]["action"], "back")
        self.assertEqual(config["buttons"][4]["action"], "forward")
        self.assertEqual(config["profile"], {"current": 1, "max": 2, "sensor_current": 1})


class BluetoothTest(unittest.TestCase):
    MAC = "AA:BB:CC:DD:EE:FF"
    DEVICES = (
        f"Device {MAC} EWEADN S9\n"
        "Device 11:22:33:44:55:66 Keyboard\n"
    )
    INFO = (
        f"Device {MAC}\n"
        "  Name: EWEADN S9\n"
        "  Connected: yes\n"
        "  Battery Percentage: 0x4b (75)\n"
    )

    def test_parse_devices(self) -> None:
        devices = module.parse_bluetooth_devices(self.DEVICES)
        self.assertEqual(devices, [(self.MAC, "EWEADN S9"), ("11:22:33:44:55:66", "Keyboard")])

    def test_parse_info(self) -> None:
        info = module.parse_bluetooth_info(self.INFO)
        self.assertTrue(info["connected"])
        self.assertEqual(info["percent"], 75)
        self.assertEqual(info["name"], "EWEADN S9")

    def test_read_bluetooth_battery(self) -> None:
        def fake_bluetoothctl(*args):
            if args == ("devices",):
                return self.DEVICES
            if args == ("info", self.MAC):
                return self.INFO
            raise AssertionError(args)

        with mock.patch.object(module, "bluetoothctl", side_effect=fake_bluetoothctl):
            result = module.read_bluetooth_battery()
        self.assertEqual(result["percent"], 75)
        self.assertEqual(result["source"], "Bluetooth")
        self.assertFalse(result["charging_known"])

    def test_read_battery_falls_back_to_bluetooth(self) -> None:
        bt = {
            "ok": True,
            "percent": 75,
            "charging": False,
            "source": "Bluetooth",
            "battery": {"percent": 75, "charging": False, "raw": None},
        }
        with mock.patch.object(
            module, "find_session", side_effect=module.DeviceNotFound("no usb")
        ), mock.patch.object(module, "read_bluetooth_battery", return_value=bt):
            result, _ = module.read_battery()
        self.assertEqual(result["source"], "Bluetooth")
        self.assertEqual(result["percent"], 75)


class PlanWriteTest(unittest.TestCase):
    def test_wireless_polling(self) -> None:
        payload, plan = module.plan_polling(CONFIG, 8000, None)
        self.assertEqual(payload, bytes([4]))
        self.assertEqual(plan["transport"], "wireless")

    def test_wired_polling_uses_high_nibble(self) -> None:
        payload, plan = module.plan_polling(CONFIG, 1000, True)
        self.assertEqual(payload, bytes([0]))
        self.assertEqual(plan["transport"], "wired")

    def test_single_adjust_sets_high_bit(self) -> None:
        config = {**CONFIG, "polling": {"is_single_adjust": True}}
        payload, _ = module.plan_polling(config, 4000, None)
        self.assertEqual(payload, bytes([0x85]))

    def test_dpi_payload(self) -> None:
        payload, plan = module.plan_dpi(CONFIG, 1, 1600, 6, "#112233")
        self.assertEqual(payload, bytes([0x16, 0x1F, 0x00, 0x11, 0x22, 0x33]))
        self.assertEqual(plan["dpi"], 1600)

    def test_dpi_rejects_bad_step(self) -> None:
        with self.assertRaises(ValueError):
            module.plan_dpi(CONFIG, 1, 1625, 6, None)

    def test_button_payload_uses_key_positions(self) -> None:
        pos, payload, plan = module.plan_button(3, "dpi_loop")
        self.assertEqual(pos, 12)
        self.assertEqual(payload, bytes([5, 4, 1, 0]))
        self.assertEqual(plan["button"], "back")

    def test_profile_cycle_payload(self) -> None:
        pos, payload, _ = module.plan_button(4, "profile_cycle")
        self.assertEqual(pos, 16)
        self.assertEqual(payload, bytes([6, 5, 0, 0]))


class ChunkSession:
    def __init__(self, replies):
        self.replies = replies

    def query(self, cmd, sub, data=b"", encap=0, **_kwargs):
        reply_value = self.replies[encap]
        if isinstance(reply_value, Exception):
            raise reply_value
        return reply_value, b""


class MultipacketIntegrityTest(unittest.TestCase):
    def test_empty_first_chunk_raises_with_context(self) -> None:
        with self.assertRaises(module.ProtocolError) as caught:
            module.read_chunks(ChunkSession([b""]), 0x4F, 0x41, 40)
        message = str(caught.exception)
        self.assertIn("expected 40 bytes", message)
        self.assertIn("received 0 bytes", message)

    def test_mid_stream_timeout_raises_with_context(self) -> None:
        session = ChunkSession(
            [bytes([0]) + b"\xAA" * 10, module.NoReply("timeout")]
        )
        with self.assertRaises(module.ProtocolError) as caught:
            module.read_chunks(session, 0x4F, 0x41, 40)
        message = str(caught.exception)
        self.assertIn("chunk 2/4", message)
        self.assertIn("expected 40 bytes", message)
        self.assertIn("received 11 bytes", message)

    def test_first_chunk_transport_error_is_preserved(self) -> None:
        session = ChunkSession([module.NoReply("asleep")])
        with self.assertRaises(module.NoReply):
            module.read_chunks(session, 0x4F, 0x41, 40)

    def test_mid_stream_empty_chunk_raises(self) -> None:
        session = ChunkSession(
            [bytes([0]) + b"\xAA" * 10, b"", b"\x02" + b"\xAA" * 10]
        )
        with self.assertRaises(module.ProtocolError):
            module.read_chunks(session, 0x4F, 0x41, 40)

    def test_short_final_buffer_raises(self) -> None:
        session = ChunkSession(
            [
                b"\xAA" * 10,
                b"\x01" + b"\xAA" * 10,
                b"\x02" + b"\xAA" * 10,
                b"\x03" + b"\xAA" * 5,
            ]
        )
        with self.assertRaises(module.ProtocolError) as caught:
            module.read_chunks(session, 0x4F, 0x41, 40)
        message = str(caught.exception)
        self.assertIn("short multipacket reply", message)
        self.assertIn("expected 40 bytes", message)
        self.assertIn("received 35 bytes", message)


class PartialConfigSession:
    path = "/dev/hidraw9"
    name = "Gaming Mouse 8K EWEADN S9"
    vendor = module.VID
    product = 0x1026

    def query(self, cmd, sub, data=b"", encap=0, **_kwargs):
        if cmd == 0x4F and sub == 0x81:
            return bytes.fromhex("64 21 07 02 30 75 04 a5 5a 00 00"), b""
        if cmd == 0x4F and sub == 0x40:
            return bytes.fromhex("02 66 36 01 03 40 20 10 01 01 00"), b""
        raise AssertionError((cmd, sub, encap))

    def close(self) -> None:
        pass


class PartialConfigTest(unittest.TestCase):
    def test_partial_dpi_table_is_rejected(self) -> None:
        session = PartialConfigSession()
        with mock.patch.object(
            module, "read_chunks", side_effect=[bytes(20), bytes(48)]
        ):
            with self.assertRaises(module.ProtocolError) as caught:
                module.read_config(session)
        self.assertIn("DPI table has", str(caught.exception))
        self.assertIn("expected 6", str(caught.exception))

    def test_partial_button_table_is_rejected(self) -> None:
        session = PartialConfigSession()
        with mock.patch.object(
            module, "read_chunks", side_effect=[bytes(64), bytes(16)]
        ):
            with self.assertRaises(module.ProtocolError) as caught:
                module.read_config(session)
        message = str(caught.exception)
        self.assertIn("button table has 4 buttons", message)
        self.assertIn("expected 5", message)


class ExactVerificationTest(unittest.TestCase):
    def test_dpi_checks_requested_stage_not_current_stage(self) -> None:
        config = verified_config()
        config["dpi"]["current_stage"] = 1
        module.verify_config(
            config,
            [
                {
                    "kind": "dpi",
                    "stage": 2,
                    "dpi": 1600,
                    "color": "#112233",
                    "stage_count": 2,
                }
            ],
        )

    def test_dpi_color_and_stage_count_mismatch(self) -> None:
        config = verified_config()
        with self.assertRaises(module.ProtocolError) as caught:
            module.verify_config(
                config,
                [
                    {
                        "kind": "dpi",
                        "stage": 2,
                        "dpi": 1600,
                        "color": "#000000",
                        "stage_count": 2,
                    }
                ],
            )
        self.assertIn("expected 1600 DPI #000000", str(caught.exception))

        with self.assertRaises(module.ProtocolError) as caught:
            module.verify_config(
                config,
                [
                    {
                        "kind": "dpi",
                        "stage": 2,
                        "dpi": 1600,
                        "color": "#112233",
                        "stage_count": 3,
                    }
                ],
            )
        self.assertIn("with 3 stages", str(caught.exception))
        self.assertIn("with 2 stages", str(caught.exception))

    def test_wired_polling_on_receiver_uses_wired_nibble(self) -> None:
        config = verified_config()
        config["device"]["wired"] = False
        config["polling"] = {
            "hz": 8000,
            "code": 4,
            "is_single_adjust": False,
        }
        config["sensor"]["wired_rate_code"] = 0
        config["sensor"]["wireless_rate_code"] = 4

        module.verify_config(
            config,
            [
                {
                    "kind": "polling",
                    "transport": "wired",
                    "code": 0,
                    "hz": 1000,
                }
            ],
        )
        with self.assertRaises(module.ProtocolError) as caught:
            module.verify_config(
                config,
                [
                    {
                        "kind": "polling",
                        "transport": "wired",
                        "code": 4,
                        "hz": 8000,
                    }
                ],
            )
        self.assertIn("wired polling", str(caught.exception))

    def test_button_verification_compares_raw_bytes(self) -> None:
        config = verified_config()
        config["buttons"][3]["action"] = "same-looking-action"
        with self.assertRaises(module.ProtocolError) as caught:
            module.verify_config(
                config,
                [
                    {
                        "kind": "button",
                        "index": 3,
                        "raw": (1, 5, 1, 0),
                    }
                ],
            )
        self.assertIn("expected raw 01 05 01 00", str(caught.exception))
        self.assertIn("read 01 04 01 00", str(caught.exception))

    def test_missing_ack_is_tolerated_when_readback_matches(self) -> None:
        session = mock.Mock()
        session.query.side_effect = module.NoReply("ack lost")
        config = verified_config()
        with mock.patch.object(module, "read_config", return_value=(config, {})):
            after = module.write_and_verify(
                session,
                0x35,
                0x01,
                bytes([4]),
                [
                    {
                        "kind": "polling",
                        "transport": "wireless",
                        "code": 4,
                        "hz": 8000,
                    }
                ],
            )
        self.assertIs(after, config)

    def test_verification_failure_reports_backup_path(self) -> None:
        session = mock.Mock()
        config = verified_config()
        config["buttons"][3]["code1"] = 2
        backup = "/tmp/eweadn-backup.json"
        with mock.patch.object(module, "read_config", return_value=(config, {})):
            with self.assertRaises(module.ProtocolError) as caught:
                module.write_and_verify(
                    session,
                    0x30,
                    12,
                    bytes([1, 4, 1, 0]),
                    [{"kind": "button", "index": 3, "raw": (1, 4, 1, 0)}],
                    backup=backup,
                )
        self.assertEqual(caught.exception.backup, backup)
        self.assertIn(backup, str(caught.exception))
        self.assertEqual(caught.exception.exit_code, 5)

    def test_set_polling_wired_on_receiver_verifies_wired_nibble(self) -> None:
        session = mock.Mock()
        before = verified_config()
        after = verified_config()
        after["sensor"]["wired_rate_code"] = 0
        after["sensor"]["wireless_rate_code"] = 4
        after["polling"]["code"] = 4
        after["polling"]["hz"] = 8000
        with mock.patch.object(
            module, "find_session", return_value=session
        ), mock.patch.object(
            module,
            "read_config",
            side_effect=[(before, {}), (after, {})],
        ), mock.patch.object(
            module, "save_backup", return_value="/tmp/safety.json"
        ):
            code, out, _err = run_main(
                [
                    "--json",
                    "set-polling",
                    "1000",
                    "--wired",
                    "--apply",
                ]
            )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertTrue(payload["applied"])
        self.assertEqual(payload["plan"]["transport"], "wired")
        session.query.assert_called_once_with(
            0x35, 0x01, bytes([0]), attempts=2, timeout=0.25
        )

    def test_set_dpi_failure_json_includes_backup(self) -> None:
        session = mock.Mock()
        before = verified_config()
        after = verified_config()
        after["dpi"]["stages"][0]["dpi"] = 900
        with mock.patch.object(
            module, "find_session", return_value=session
        ), mock.patch.object(
            module,
            "read_config",
            side_effect=[(before, {}), (after, {})],
        ), mock.patch.object(
            module, "save_backup", return_value="/tmp/safety.json"
        ):
            code, out, _err = run_main(
                [
                    "--json",
                    "set-dpi",
                    "1",
                    "800",
                    "--stage-count",
                    "2",
                    "--apply",
                ]
            )
        self.assertEqual(code, 5)
        payload = json.loads(out)
        self.assertEqual(payload["backup"], "/tmp/safety.json")
        self.assertIn("/tmp/safety.json", payload["error"])
        session.close.assert_called_once()


class FailureContractTest(unittest.TestCase):
    def test_expected_oserror_mapping(self) -> None:
        cases = {
            errno.ENODEV: module.DeviceNotFound,
            errno.ENOENT: module.DeviceNotFound,
            errno.EIO: module.NoReply,
            errno.ESHUTDOWN: module.NoReply,
            errno.EACCES: module.PermissionDenied,
            errno.EPERM: module.PermissionDenied,
        }
        for code, expected in cases.items():
            with self.subTest(errno=code):
                error = module.map_os_error(
                    OSError(code, os.strerror(code)), "test"
                )
                self.assertIsInstance(error, expected)

    def test_hidsession_open_errors_are_mapped(self) -> None:
        cases = {
            errno.ENODEV: module.DeviceNotFound,
            errno.EACCES: module.PermissionDenied,
            errno.EIO: module.NoReply,
        }
        for code, expected in cases.items():
            with self.subTest(errno=code):
                with mock.patch.object(
                    module.os,
                    "open",
                    side_effect=OSError(code, os.strerror(code)),
                ):
                    with self.assertRaises(expected):
                        module.HidSession("/dev/hidraw9", "EWEADN", module.VID, 0x1026, None)

    def test_ioctl_permission_and_io_errors_are_mapped(self) -> None:
        with mock.patch.object(module.os, "open", return_value=123):
            session = module.HidSession(
                "/dev/hidraw9", "EWEADN", module.VID, 0x1026, None
            )
        with mock.patch.object(
            module.fcntl,
            "ioctl",
            side_effect=OSError(errno.EACCES, "denied"),
        ), mock.patch.object(module.time, "sleep"):
            with self.assertRaises(module.PermissionDenied):
                session.query(0x4F, 0x81, attempts=1)
        with mock.patch.object(
            module.fcntl, "ioctl", side_effect=OSError(errno.EIO, "io")
        ), mock.patch.object(module.time, "sleep"):
            with self.assertRaises(module.NoReply):
                session.query(0x4F, 0x81, attempts=1)

    def test_main_oserror_json_contract(self) -> None:
        with mock.patch.object(
            module,
            "command_battery",
            side_effect=OSError(errno.EIO, "io failure"),
        ):
            code, out, _err = run_main(["--json"])
        self.assertEqual(code, 4)
        payload = json.loads(out)
        self.assertFalse(payload["ok"])
        self.assertIn("I/O error", payload["error"])

    def test_main_permission_json_contract(self) -> None:
        with mock.patch.object(
            module,
            "command_battery",
            side_effect=OSError(errno.EACCES, "denied"),
        ):
            code, out, _err = run_main(["--json"])
        self.assertEqual(code, 3)
        self.assertIn("permission denied", json.loads(out)["error"])

    def test_stage_count_zero_is_validation_error(self) -> None:
        code, out, _err = run_main(
            ["--json", "set-dpi", "1", "1600", "--stage-count", "0"]
        )
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertFalse(payload["ok"])
        self.assertIn("stage count", payload["error"])

    def test_empty_color_is_validation_error(self) -> None:
        code, out, _err = run_main(
            ["--json", "set-dpi", "1", "1600", "--color", ""]
        )
        self.assertEqual(code, 1)
        self.assertIn("color", json.loads(out)["error"])

    def test_argparse_error_uses_exit_one_and_json(self) -> None:
        out = io.StringIO()
        with self.assertRaises(SystemExit) as caught:
            with contextlib.redirect_stdout(out):
                module.main(["--json", "set-dpi", "not-an-int"])
        self.assertEqual(caught.exception.code, 1)
        payload = json.loads(out.getvalue())
        self.assertFalse(payload["ok"])

    def test_backup_io_errors_are_user_facing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, "backup.json")
            with mock.patch.object(
                module.tempfile,
                "mkstemp",
                side_effect=OSError(errno.EACCES, "denied"),
            ):
                with self.assertRaises(module.BackupError) as caught:
                    module.save_backup({}, target)
        self.assertIn("could not write backup", str(caught.exception))
        self.assertEqual(caught.exception.exit_code, 1)


class BackupRestoreTest(unittest.TestCase):
    def test_backup_creation_mode_and_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = os.path.join(directory, "state")
            with mock.patch.dict(
                os.environ, {"XDG_STATE_HOME": state}, clear=False
            ):
                path = module.save_backup({"ok": True, "value": 7})
            self.assertTrue(os.path.isfile(path))
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            backups = os.path.join(state, "eweadn-linux-control", "backups")
            self.assertEqual(stat.S_IMODE(os.stat(backups).st_mode), 0o700)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(
                    json.load(handle), {"ok": True, "value": 7}
                )
            leftovers = [
                name for name in os.listdir(backups) if name.endswith(".tmp")
            ]
            self.assertEqual(leftovers, [])

    def test_automatic_backup_does_not_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, "eweadn-config-fixed.json")
            pathlib.Path(target).write_text("old", encoding="utf-8")
            with mock.patch.object(module, "backup_path", return_value=target):
                new_path = module.save_backup({"ok": True, "value": 2})
            self.assertNotEqual(new_path, target)
            self.assertEqual(
                pathlib.Path(target).read_text(encoding="utf-8"), "old"
            )
            with open(new_path, encoding="utf-8") as handle:
                self.assertEqual(json.load(handle), {"ok": True, "value": 2})
            self.assertEqual(stat.S_IMODE(os.stat(new_path).st_mode), 0o600)

    def test_failed_replace_leaves_old_backup_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = os.path.join(directory, "backup.json")
            pathlib.Path(target).write_text("old", encoding="utf-8")
            with mock.patch.object(
                module.os, "replace", side_effect=OSError(errno.EIO, "disk")
            ):
                with self.assertRaises(module.BackupError):
                    module.save_backup({"ok": True}, target)
            self.assertEqual(
                pathlib.Path(target).read_text(encoding="utf-8"), "old"
            )
            leftovers = [
                name for name in os.listdir(directory) if name.endswith(".tmp")
            ]
            self.assertEqual(leftovers, [])

    def test_backup_rejects_symlink_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            real = os.path.join(directory, "real.json")
            link = os.path.join(directory, "link.json")
            pathlib.Path(real).write_text("keep", encoding="utf-8")
            os.symlink(real, link)
            with self.assertRaises(module.BackupError):
                module.save_backup({"ok": True}, link)
            self.assertEqual(
                pathlib.Path(real).read_text(encoding="utf-8"), "keep"
            )

    def test_restore_plan_covers_polling_dpi_and_buttons(self) -> None:
        document = backup_document()
        document["dpi"]["current_stage"] = 1
        operations, plan = module.plan_restore(document)

        self.assertEqual(plan["polling"]["hz"], 8000)
        self.assertEqual(plan["polling"]["transport"], "wireless")
        self.assertEqual(len(plan["buttons"]), 5)
        self.assertEqual(
            plan["dpi"]["stages"][0]["color"], "#ff0000"
        )
        self.assertEqual(operations[0]["payload"], bytes([4]))
        dpi_operations = [
            operation
            for operation in operations
            if operation["expected"]["kind"] == "dpi"
        ]
        self.assertEqual(
            [operation["expected"]["stage"] for operation in dpi_operations],
            [2, 1],
        )
        button_operations = [
            operation
            for operation in operations
            if operation["expected"]["kind"] == "button"
        ]
        self.assertEqual(len(button_operations), 5)
        self.assertEqual(
            button_operations[0]["payload"], bytes([1, 1, 1, 0])
        )

    def test_restore_plan_wired_polling(self) -> None:
        document = backup_document()
        document["device"]["wired"] = True
        document["polling"] = {
            "hz": 8000,
            "code": 4,
            "is_single_adjust": False,
        }
        operations, plan = module.plan_restore(document)
        self.assertEqual(plan["polling"]["transport"], "wired")
        self.assertEqual(operations[0]["payload"], bytes([0x40]))

    def test_restore_dry_run_does_not_touch_hardware(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "backup.json")
            pathlib.Path(path).write_text(
                json.dumps(backup_document()), encoding="utf-8"
            )
            with mock.patch.object(module, "find_session") as find:
                code, out, _err = run_main(
                    ["restore", "--backup", path, "--json"]
                )
        self.assertEqual(code, 0)
        find.assert_not_called()
        payload = json.loads(out)
        self.assertTrue(payload["dry_run"])
        self.assertEqual(payload["source"], os.path.abspath(path))
        self.assertEqual(len(payload["plan"]["buttons"]), 5)

    def test_restore_rejects_invalid_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "backup.json")
            document = backup_document()
            document["buttons"] = document["buttons"][:4]
            pathlib.Path(path).write_text(
                json.dumps(document), encoding="utf-8"
            )
            code, out, _err = run_main(
                ["restore", "--backup", path, "--json"]
            )
        self.assertEqual(code, 1)
        self.assertIn("five buttons", json.loads(out)["error"])

    def test_restore_apply_verifies_and_reports_backup(self) -> None:
        document = backup_document()
        after = verified_config()
        after["dpi"]["current_stage"] = 2
        after["dpi"]["stages"][1]["color"] = "#00ff00"
        current = verified_config()
        session = mock.Mock()
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "backup.json")
            pathlib.Path(path).write_text(
                json.dumps(document), encoding="utf-8"
            )
            with mock.patch.object(
                module, "find_session", return_value=session
            ), mock.patch.object(
                module,
                "read_config",
                side_effect=[(current, {}), (after, {})],
            ), mock.patch.object(
                module, "save_backup", return_value="/tmp/safety.json"
            ):
                code, out, _err = run_main(
                    ["restore", "--backup", path, "--apply", "--json"]
                )
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertTrue(payload["applied"])
        self.assertEqual(payload["backup"], "/tmp/safety.json")
        self.assertEqual(session.query.call_count, 8)
        session.close.assert_called_once()

    def test_restore_verification_failure_includes_backup(self) -> None:
        document = backup_document()
        after = verified_config()
        after["dpi"]["current_stage"] = 1
        after["dpi"]["stages"][1]["color"] = "#00ff00"
        session = mock.Mock()
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "backup.json")
            pathlib.Path(path).write_text(
                json.dumps(document), encoding="utf-8"
            )
            with mock.patch.object(
                module, "find_session", return_value=session
            ), mock.patch.object(
                module,
                "read_config",
                side_effect=[(verified_config(), {}), (after, {})],
            ), mock.patch.object(
                module, "save_backup", return_value="/tmp/safety.json"
            ):
                code, out, _err = run_main(
                    ["restore", "--backup", path, "--apply", "--json"]
                )
        self.assertEqual(code, 5)
        payload = json.loads(out)
        self.assertEqual(payload["backup"], "/tmp/safety.json")
        self.assertIn("/tmp/safety.json", payload["error"])


class LockTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = os.path.join(self.temp.name, "runtime")
        os.mkdir(self.runtime, 0o700)
        os.chmod(self.runtime, 0o700)
        self.state = os.path.join(self.temp.name, "state")
        self.env = {
            "XDG_RUNTIME_DIR": self.runtime,
            "XDG_STATE_HOME": self.state,
        }

    def test_preferred_runtime_lock_path(self) -> None:
        with mock.patch.dict(os.environ, self.env, clear=False):
            self.assertEqual(
                module.lock_path(),
                os.path.join(self.runtime, "eweadn-linux-control.lock"),
            )

    def test_unverified_runtime_falls_back_to_state_directory(self) -> None:
        os.chmod(self.runtime, 0o777)
        with mock.patch.dict(os.environ, self.env, clear=False):
            self.assertEqual(
                module.lock_path(),
                os.path.join(
                    self.state, "eweadn-linux-control", "lock"
                ),
            )

    def test_lock_file_is_regular_and_mode_0600(self) -> None:
        with mock.patch.dict(os.environ, self.env, clear=False):
            path = module.lock_path()
            preexisting = os.open(path, os.O_CREAT | os.O_WRONLY, 0o644)
            os.close(preexisting)
            fd = module.acquire_lock()
            try:
                info = os.fstat(fd)
                self.assertTrue(stat.S_ISREG(info.st_mode))
                self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
                self.assertEqual(info.st_uid, os.getuid())
            finally:
                module.release_lock(fd)

    def test_busy_lock_times_out_and_closes_fd(self) -> None:
        opened = []
        real_open = os.open

        def recording_open(*args, **kwargs):
            fd = real_open(*args, **kwargs)
            opened.append(fd)
            return fd

        with mock.patch.dict(os.environ, self.env, clear=False):
            with mock.patch.object(
                module.os, "open", side_effect=recording_open
            ), mock.patch.object(
                module.fcntl,
                "flock",
                side_effect=BlockingIOError(errno.EWOULDBLOCK, "busy"),
            ), mock.patch.object(
                module, "LOCK_TIMEOUT", 0.0
            ):
                with self.assertRaises(module.LockError) as caught:
                    module.acquire_lock()
        self.assertIn("busy", str(caught.exception))
        self.assertEqual(len(opened), 1)
        with self.assertRaises(OSError):
            os.fstat(opened[0])

    def test_lock_is_released_when_opening_device_fails(self) -> None:
        nodes = [("/dev/hidraw9", "EWEADN", module.VID, 0x1026)]
        with mock.patch.dict(os.environ, self.env, clear=False):
            with mock.patch.object(
                module, "candidates", return_value=nodes
            ), mock.patch.object(
                module,
                "HidSession",
                side_effect=module.PermissionDenied("denied"),
            ):
                with self.assertRaises(module.PermissionDenied):
                    module.find_session()

            path = module.lock_path()
            fd = os.open(path, os.O_RDWR)
            try:
                module.fcntl.flock(
                    fd, module.fcntl.LOCK_EX | module.fcntl.LOCK_NB
                )
                module.fcntl.flock(fd, module.fcntl.LOCK_UN)
            finally:
                os.close(fd)

    def test_symlink_lock_is_rejected(self) -> None:
        target = os.path.join(self.runtime, "target")
        pathlib.Path(target).write_text("x", encoding="utf-8")
        os.symlink(target, os.path.join(self.runtime, "eweadn-linux-control.lock"))
        with mock.patch.dict(os.environ, self.env, clear=False):
            with self.assertRaises(module.LockError):
                module.acquire_lock()

    def test_lock_directory_errors_are_user_facing(self) -> None:
        state_file = os.path.join(self.temp.name, "not-a-directory")
        pathlib.Path(state_file).write_text("x", encoding="utf-8")
        env = {
            "XDG_RUNTIME_DIR": os.path.join(self.temp.name, "missing"),
            "XDG_STATE_HOME": state_file,
        }
        with mock.patch.dict(os.environ, env, clear=False):
            with self.assertRaises(module.LockError) as caught:
                module.acquire_lock()
        self.assertIn("lock directory", str(caught.exception))

    def test_candidates_are_enumerated_again_after_lock(self) -> None:
        nodes = [("/dev/hidraw9", "EWEADN", module.VID, 0x1026)]
        session = object()
        with mock.patch.object(
            module, "candidates", side_effect=[nodes, nodes]
        ) as found, mock.patch.object(
            module, "acquire_lock", return_value=77
        ), mock.patch.object(
            module, "HidSession", return_value=session
        ):
            self.assertIs(module.find_session(), session)
        self.assertEqual(found.call_count, 2)


class FallbackPolicyTest(unittest.TestCase):
    MAC = "AA:BB:CC:DD:EE:FF"
    MAC2 = "11:22:33:44:55:66"

    def bluetooth_result(self) -> dict:
        return {
            "ok": True,
            "percent": 80,
            "charging": False,
            "charging_known": False,
            "status": None,
            "path": self.MAC2,
            "name": "EWEADN S9",
            "vendor": "",
            "product": "",
            "source": "Bluetooth",
            "raw": "battery=80",
            "battery": {"percent": 80, "charging": False, "raw": None},
        }

    def test_permission_error_does_not_fall_back(self) -> None:
        with mock.patch.object(
            module,
            "find_session",
            side_effect=module.PermissionDenied("denied"),
        ), mock.patch.object(module, "read_bluetooth_battery") as bluetooth:
            with self.assertRaises(module.PermissionDenied):
                module.read_battery()
        bluetooth.assert_not_called()

    def test_protocol_error_from_present_usb_does_not_fall_back(self) -> None:
        session = mock.Mock()
        session.query.side_effect = module.ProtocolError("broken")
        with mock.patch.object(module, "read_bluetooth_battery") as bluetooth:
            with self.assertRaises(module.ProtocolError):
                module.read_battery(session)
        bluetooth.assert_not_called()

    def test_no_reply_falls_back_to_bluetooth(self) -> None:
        session = mock.Mock()
        session.query.side_effect = module.NoReply("asleep")
        result = self.bluetooth_result()
        with mock.patch.object(
            module, "read_bluetooth_battery", return_value=result
        ):
            battery, _raw = module.read_battery(session)
        self.assertEqual(battery["source"], "Bluetooth")

    def test_generic_s9_name_is_not_an_eweadn_device(self) -> None:
        with mock.patch.object(
            module,
            "bluetoothctl",
            return_value=f"Device {self.MAC} Keyboard S9\n",
        ) as bluetooth:
            with self.assertRaises(module.DeviceNotFound):
                module.read_bluetooth_battery()
        bluetooth.assert_called_once_with("devices")

    def test_disconnected_device_is_skipped(self) -> None:
        def fake_bluetoothctl(*args):
            if args == ("devices",):
                return f"Device {self.MAC} EWEADN S9\n"
            if args == ("info", self.MAC):
                return (
                    f"Device {self.MAC}\n"
                    "  Name: EWEADN S9\n"
                    "  Connected: no\n"
                    "  Battery Percentage: 0x4b (75)\n"
                )
            raise AssertionError(args)

        with mock.patch.object(
            module, "bluetoothctl", side_effect=fake_bluetoothctl
        ):
            with self.assertRaises(module.DeviceNotFound):
                module.read_bluetooth_battery()

    def test_connected_device_without_battery_is_skipped(self) -> None:
        def fake_bluetoothctl(*args):
            if args == ("devices",):
                return f"Device {self.MAC} EWEADN S9\n"
            if args == ("info", self.MAC):
                return (
                    f"Device {self.MAC}\n"
                    "  Name: EWEADN S9\n"
                    "  Connected: yes\n"
                )
            raise AssertionError(args)

        with mock.patch.object(
            module, "bluetoothctl", side_effect=fake_bluetoothctl
        ):
            with self.assertRaises(module.DeviceNotFound):
                module.read_bluetooth_battery()

    def test_bluetooth_timeout_is_no_reply(self) -> None:
        with mock.patch.object(
            module,
            "bluetoothctl",
            side_effect=module.NoReply("timed out"),
        ):
            with self.assertRaises(module.NoReply):
                module.read_bluetooth_battery()

    def test_per_candidate_timeout_tries_next_device(self) -> None:
        def fake_bluetoothctl(*args):
            if args == ("devices",):
                return (
                    f"Device {self.MAC} EWEADN S9\n"
                    f"Device {self.MAC2} EWEADN S9\n"
                )
            if args == ("info", self.MAC):
                raise module.NoReply("timeout")
            if args == ("info", self.MAC2):
                return (
                    f"Device {self.MAC2}\n"
                    "  Name: EWEADN S9\n"
                    "  Connected: yes\n"
                    "  Battery Percentage: 80\n"
                )
            raise AssertionError(args)

        with mock.patch.object(
            module, "bluetoothctl", side_effect=fake_bluetoothctl
        ):
            result = module.read_bluetooth_battery()
        self.assertEqual(result["percent"], 80)
        self.assertEqual(result["path"], self.MAC2)

    def test_both_links_failing_reports_both_errors(self) -> None:
        with mock.patch.object(
            module,
            "find_session",
            side_effect=module.DeviceNotFound("receiver missing"),
        ), mock.patch.object(
            module,
            "read_bluetooth_battery",
            side_effect=module.DeviceNotFound("bluetooth missing"),
        ):
            with self.assertRaises(module.DeviceNotFound) as caught:
                module.read_battery()
        message = str(caught.exception)
        self.assertIn("receiver missing", message)
        self.assertIn("bluetooth missing", message)

    def test_config_does_not_hide_broken_usb_as_bluetooth(self) -> None:
        args = argparse.Namespace(debug=False)
        with mock.patch.object(
            module,
            "read_config",
            side_effect=module.ProtocolError("broken usb"),
        ), mock.patch.object(module, "bluetooth_config") as bluetooth:
            with self.assertRaises(module.ProtocolError):
                module.command_config(args, True)
        bluetooth.assert_not_called()

    def test_config_reports_both_failures(self) -> None:
        args = argparse.Namespace(debug=False)
        with mock.patch.object(
            module,
            "read_config",
            side_effect=module.DeviceNotFound("no receiver"),
        ), mock.patch.object(
            module,
            "bluetooth_config",
            side_effect=module.DeviceNotFound("no bluetooth"),
        ):
            with self.assertRaises(module.DeviceNotFound) as caught:
                module.command_config(args, True)
        message = str(caught.exception)
        self.assertIn("no receiver", message)
        self.assertIn("no bluetooth", message)

    def test_bluetoothctl_nonzero_exit_is_an_error(self) -> None:
        completed = subprocess.CompletedProcess(
            [], 1, "", "Failed to connect"
        )
        with mock.patch.object(
            module, "resolve_bluetoothctl", return_value="/usr/bin/bluetoothctl"
        ), mock.patch.object(
            module.subprocess, "run", return_value=completed
        ):
            with self.assertRaises(module.NoReply) as caught:
                module.bluetoothctl("devices")
        self.assertIn("failed", str(caught.exception))

    def test_first_valid_battery_property_wins(self) -> None:
        info = (
            "Connected: yes\n"
            "Battery Percentage: 0x4b (85)\n"
            "Battery Percentage: 0x4b (75)\n"
        )
        self.assertEqual(module.parse_bluetooth_info(info)["percent"], 85)
        info = (
            "Connected: yes\n"
            "Battery Percentage: 0x4b (175)\n"
            "Battery Percentage: 0x4b (75)\n"
        )
        self.assertEqual(module.parse_bluetooth_info(info)["percent"], 75)

    def test_bluetooth_names_are_sanitized(self) -> None:
        devices = module.parse_bluetooth_devices(
            f"Device {self.MAC} \x1b[31mEWEADN\x07 S9\n"
        )
        self.assertEqual(len(devices), 1)
        self.assertNotIn("\x1b", devices[0][1])
        self.assertNotIn("\x07", devices[0][1])

    def test_bluetoothctl_resolution_requires_absolute_path(self) -> None:
        with mock.patch.object(
            module.shutil, "which", return_value="/usr/bin/bluetoothctl"
        ):
            self.assertEqual(
                module.resolve_bluetoothctl(), "/usr/bin/bluetoothctl"
            )
        with mock.patch.object(module.shutil, "which", return_value=None):
            with self.assertRaises(module.DeviceNotFound):
                module.resolve_bluetoothctl()
        with mock.patch.object(
            module.shutil, "which", return_value="bluetoothctl"
        ):
            with self.assertRaises(module.DeviceNotFound):
                module.resolve_bluetoothctl()


class DiscoveryTest(unittest.TestCase):
    def test_descriptor_parser_requires_vendor_feature_report(self) -> None:
        self.assertTrue(module.descriptor_matches(descriptor()))
        self.assertFalse(
            module.descriptor_matches(descriptor(usage_page=0x0001))
        )
        self.assertFalse(module.descriptor_matches(descriptor(report_id=2)))
        self.assertFalse(
            module.descriptor_matches(descriptor(main_tag=0x08))
        )
        self.assertFalse(module.descriptor_matches(b"\x06\x00"))

    def test_candidates_select_only_the_vendor_interface(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            make_hidraw(
                directory,
                "hidraw0",
                0x1026,
                descriptor(),
                "Gaming Mouse 8K EWEADN S9",
            )
            make_hidraw(
                directory,
                "hidraw1",
                0x1026,
                descriptor(usage_page=0x0001),
                "Gaming Mouse 8K EWEADN S9",
            )
            make_hidraw(
                directory,
                "hidraw2",
                0x1026,
                descriptor(main_tag=0x08),
                "Gaming Mouse 8K EWEADN S9",
            )
            make_hidraw(
                directory, "hidraw3", 0x1026, descriptor(report_id=2)
            )
            make_hidraw(directory, "hidraw4", 0x1026, None)
            make_hidraw(
                directory,
                "hidraw5",
                0x9999,
                descriptor(),
                "Other device",
                vendor=0x9999,
            )
            found = module.candidates(directory)
        self.assertEqual([entry[0] for entry in found], ["/dev/hidraw0"])
        self.assertEqual(found[0][1], "Gaming Mouse 8K EWEADN S9")
        self.assertEqual(found[0][3], 0x1026)

    def test_candidates_returns_multiple_vendor_nodes_sorted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            make_hidraw(directory, "hidraw2", 0x1026, descriptor())
            make_hidraw(directory, "hidraw1", 0x103D, descriptor())
            found = module.candidates(directory)
        self.assertEqual(
            [entry[0] for entry in found],
            ["/dev/hidraw1", "/dev/hidraw2"],
        )

    def test_all_known_pids_get_sensible_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for index, product in enumerate(sorted(module.KNOWN_PIDS)):
                make_hidraw(
                    directory,
                    f"hidraw{index}",
                    product,
                    descriptor(),
                    "USB Composite Device",
                )
            found = module.candidates(directory)
        self.assertEqual(len(found), len(module.KNOWN_PIDS))
        for _path, name, _vendor, product in found:
            self.assertTrue(name.startswith("EWEADN"), name)
            self.assertEqual(
                name,
                module.PRODUCT_NAMES.get(
                    product, f"EWEADN device {product:04x}"
                ),
            )


class OutputHygieneTest(unittest.TestCase):
    def test_sanitize_name_removes_control_and_ansi(self) -> None:
        cleaned = module.sanitize_name(
            "\x1b[31mEvil\nMouse\x07\tX\r"
        )
        self.assertEqual(cleaned, "Evil Mouse X")
        for character in "\x00\x07\x1b\r\n\t":
            self.assertNotIn(character, cleaned)

    def test_human_battery_output_is_sanitized(self) -> None:
        value = {
            "ok": True,
            "name": "Evil\nMouse\x1b[31m",
            "battery": {"percent": 50, "charging": False},
        }
        _result, out, _err = capture_call(module.emit, value, False)
        self.assertEqual(out, "Evil Mouse: 50%\n")

    def test_json_error_output_is_one_object(self) -> None:
        value = {
            "ok": True,
            "name": "Evil\nMouse",
            "battery": {"percent": 50, "charging": False},
        }
        _result, out, _err = capture_call(module.emit, value, True)
        self.assertEqual(len(out.splitlines()), 1)
        self.assertEqual(json.loads(out)["name"], "Evil\nMouse")

    def test_print_config_sanitizes_device_name(self) -> None:
        config = verified_config()
        config["device"]["name"] = "Evil\nMouse\x1b[31m"
        _result, out, _err = capture_call(module.print_config, config)
        self.assertNotIn("\x1b", out)
        self.assertIn("Evil Mouse", out)

    def test_debug_implies_json_and_includes_raw_frames(self) -> None:
        config = verified_config()
        raw = {"basics": "03 50", "sensor": "03 50"}
        with mock.patch.object(
            module, "read_config", return_value=(config, raw)
        ):
            code, out, _err = run_main(["config", "--debug"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["raw"], raw)

    def test_help_documents_validation_exit_code(self) -> None:
        help_text = module.build_parser().format_help()
        self.assertIn("1 validation", help_text)
        self.assertIn("5 unexpected", help_text)


if __name__ == "__main__":
    unittest.main()
