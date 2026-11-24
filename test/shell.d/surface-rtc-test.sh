#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
cd "$ROOT"

python3 -B - <<'PY'
import ctypes
import datetime
import runpy
import struct
import unittest
from unittest.mock import Mock, patch

probe = runpy.run_path("contrib/surface-laptop-ultra/diagnostics/surface-rtc.py")
request = probe["read_request"]
sample = probe["sample"]
calendar = probe["decode_calendar"]
main = probe["main"]
clock = struct.Struct("<H6BHhB3x")
epoch = int(datetime.datetime(2025, 1, 2, tzinfo=datetime.timezone.utc).timestamp())


class ClockTest(unittest.TestCase):
  def test_read_only_request_and_return_validation(self):
    def respond(fd, ioctl, packet):
      self.assertEqual(fd, 7)
      self.assertEqual(ioctl, 0xC028A501)
      self.assertEqual(packet[:24], bytes.fromhex(
        "010110000100000000000000000000000000000000000000"
      ))
      address, length = struct.unpack_from("<QH", packet, 24)
      self.assertEqual(length, 4)
      ctypes.memmove(address, b"1234", 4)
      struct.pack_into("<H", packet, 32, 4)

    with patch("fcntl.ioctl", side_effect=respond) as ioctl:
      self.assertEqual(request(7, 0x10, 4), b"1234")
      ioctl.assert_called_once()

    def short_reply(fd, ioctl, packet):
      struct.pack_into("<H", packet, 32, 0)

    with patch("fcntl.ioctl", side_effect=short_reply):
      with self.assertRaisesRegex(ValueError, "response length"):
        request(7, 0x10, 4)

    def fail(fd, ioctl, packet):
      struct.pack_into("<h", packet, 6, -110)

    with patch("fcntl.ioctl", side_effect=fail):
      with self.assertRaisesRegex(OSError, "request 0x10"):
        request(7, 0x10, 4)

  def test_calendar_validity_and_civil_time(self):
    self.assertEqual(calendar(clock.pack(2025, 1, 2, 0, 0, 0, 1, 0, -480, 0)),
                     (epoch, -480))
    with self.assertRaisesRegex(ValueError, "invalid"):
      calendar(clock.pack(2025, 1, 2, 0, 0, 0, 0, 0, 2047, 0))
    with self.assertRaises(ValueError):
      calendar(clock.pack(2025, 2, 30, 0, 0, 0, 1, 0, 2047, 0))

  def test_pair_brackets_second_rollover(self):
    read = Mock(side_effect=[
      struct.pack("<I", epoch + 28799),
      clock.pack(2025, 1, 2, 0, 0, 0, 1, 0, 2047, 0),
      struct.pack("<I", epoch + 28800),
    ])
    with patch("time.time", side_effect=[epoch + 1, epoch + 1]), \
         patch("time.monotonic", side_effect=[0, 0.1]):
      report = sample(read_efi=lambda: epoch + 1, read=read)
    self.assertEqual([call.args for call in read.call_args_list],
                     [(0x10, 4), (0x1f, 16), (0x10, 4)])
    self.assertEqual(report["sam_calendar_minus_timestamp_s"], [-28800, -28799])

  def test_slow_sample_rejected(self):
    read = Mock(return_value=bytes(4))
    with patch("time.time", side_effect=[epoch, epoch]), \
         patch("time.monotonic", side_effect=[0, 3]):
      read.side_effect = [
        struct.pack("<I", epoch), clock.pack(2025, 1, 2, 0, 0, 0, 1, 0, 2047, 0),
        struct.pack("<I", epoch),
      ]
      with self.assertRaisesRegex(ValueError, "sample window"):
        sample(read_efi=lambda: epoch, read=read)

  def test_other_models_never_open_controller(self):
    with patch("pathlib.Path.read_text", return_value="Other model"), \
         patch("builtins.open") as device, patch("sys.stderr"):
      self.assertEqual(main(), 1)
      device.assert_not_called()


unittest.main()
PY
