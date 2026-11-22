from __future__ import annotations

import importlib.machinery
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin" / "eweadn-battery"

loader = importlib.machinery.SourceFileLoader("eweadn_battery", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


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
                return bytes([sub, encap]) + bytes(9), b""

        data = module.read_chunks(FakeSession(), 0x4F, 0x41, 40)
        self.assertEqual(len(data), 40)
        self.assertEqual(data[:2], bytes([0x41, 0]))
        self.assertEqual(data[11:13], bytes([0x42, 1]))


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


if __name__ == "__main__":
    unittest.main()
