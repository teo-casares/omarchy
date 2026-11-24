"""Compare the Surface Laptop Ultra's system clock, EFI RTC and SAM clock views."""

import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import struct
import sys
import time

AGGREGATOR = "/dev/surface/aggregator"
SSAM_CDEV_REQUEST = 0xC028A501
REQUEST = struct.Struct("<BBBBHhQH6xQH6x")
ACPI_CALENDAR = struct.Struct("<H6BHhB3x")
READ_TIMESTAMP = 0x10
READ_CALENDAR = 0x1f


def read_request(fd, command, size):
  # Linux surface_aggregator/cdev.h. Flag 1 requests a reply and the
  # payload address and length are both zero for these read commands.
  response = ctypes.create_string_buffer(size)
  packet = bytearray(REQUEST.pack(1, 1, command, 0, 1, 0, 0, 0,
                                  ctypes.addressof(response), size))
  fcntl.ioctl(fd, SSAM_CDEV_REQUEST, packet)
  _, _, _, _, _, status, _, _, _, length = REQUEST.unpack(packet)
  if status:
    raise OSError(abs(status), f"SAM request 0x{command:02x}: {os.strerror(abs(status))}")
  if length != size:
    raise ValueError(f"SAM request 0x{command:02x}: expected response length {size}, got {length}")
  return response.raw


def decode_calendar(response):
  year, month, day, hour, minute, second, valid, _, tz_minutes, _ = ACPI_CALENDAR.unpack(response)
  if valid != 1:
    raise ValueError("SAM calendar marked invalid")
  # Compare the displayed fields to UTC without applying the reported zone.
  # The zone field can be 2047 (unspecified) even when the views differ.
  civil_time = datetime.datetime(year, month, day, hour, minute, second,
                                 tzinfo=datetime.timezone.utc)
  return int(civil_time.timestamp()), tz_minutes


def read_efi_rtc():
  for name in sorted(Path("/sys/class/rtc").glob("rtc*/name")):
    if name.read_text().split(maxsplit=1)[:1] == ["rtc-efi"]:
      return int(name.with_name("since_epoch").read_text())
  raise ValueError("no rtc-efi device in /sys/class/rtc")


def sample(read_efi, read):
  start = time.monotonic()
  host_before = time.time()
  timestamp_before, = struct.unpack("<I", read(READ_TIMESTAMP, 4))
  calendar_epoch, calendar_zone = decode_calendar(read(READ_CALENDAR, ACPI_CALENDAR.size))
  efi = read_efi()
  timestamp_after, = struct.unpack("<I", read(READ_TIMESTAMP, 4))
  host_after = time.time()
  end = time.monotonic()
  elapsed = end - start

  if elapsed > 2 or host_after < host_before or abs(host_after - host_before - elapsed) > 0.25:
    raise ValueError("sample window exceeded two seconds or the system clock stepped; retry")
  if not 0 <= timestamp_after - timestamp_before <= 2:
    raise ValueError("SAM Unix timestamp changed unexpectedly during the sample; retry")

  host_min = int(host_before)
  host_max = int(host_after)
  return {
    "sample_monotonic_window_s": [round(start, 3), round(end, 3)],
    "system_epoch_window": [host_min, host_max],
    "efi_rtc_epoch": efi,
    "sam_timestamp_window": [timestamp_before, timestamp_after],
    "sam_calendar_as_utc_epoch": calendar_epoch,
    "sam_calendar_reported_zone_minutes": calendar_zone,
    "sam_calendar_minus_timestamp_s": [calendar_epoch - timestamp_after,
                                       calendar_epoch - timestamp_before],
    "sam_calendar_minus_system_s": [calendar_epoch - host_max, calendar_epoch - host_min],
    "sam_timestamp_minus_system_s": [timestamp_before - host_max, timestamp_after - host_min],
    "efi_rtc_minus_system_s": [efi - host_max, efi - host_min],
  }


def main():
  try:
    if Path("/sys/class/dmi/id/product_name").read_text().strip() != "Microsoft Surface Laptop Ultra":
      raise ValueError("this diagnostic requires a Microsoft Surface Laptop Ultra")
    with open(AGGREGATOR, "rb", buffering=0) as controller:
      fd = controller.fileno()
      report = sample(read_efi_rtc, lambda command, size: read_request(fd, command, size))
  except FileNotFoundError as error:
    print(f"surface-rtc: {error}", file=sys.stderr)
    if error.filename == AGGREGATOR:
      print("The SAM device requires surface_aggregator_cdev.", file=sys.stderr)
    return 1
  except (OSError, ValueError) as error:
    print(f"surface-rtc: {error}", file=sys.stderr)
    return 1
  print(json.dumps(report, indent=2))
  return 0


if __name__ == "__main__":
  if len(sys.argv) != 1:
    sys.exit("Usage: python3 -I surface-rtc.py")
  sys.exit(main())
