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


class ParseReplyTest(unittest.TestCase):
    def test_discharging_percentage(self) -> None:
        result = module.parse_reply(reply(0x35))
        self.assertEqual(result["percent"], 53)
        self.assertFalse(result["charging"])

    def test_low_battery(self) -> None:
        result = module.parse_reply(reply(0x0F))
        self.assertEqual(result["percent"], 15)
        self.assertFalse(result["charging"])

    def test_charging_sentinel_has_no_percentage(self) -> None:
        result = module.parse_reply(reply(0xE4))
        self.assertIsNone(result["percent"])
        self.assertTrue(result["charging"])

    def test_invalid_percentage(self) -> None:
        with self.assertRaises(ValueError):
            module.parse_reply(reply(0x7F))

    def test_ioctl_constants(self) -> None:
        self.assertEqual(module.HIDIOCSFEATURE, 0xC0404806)
        self.assertEqual(module.HIDIOCGFEATURE, 0xC0404807)


if __name__ == "__main__":
    unittest.main()
