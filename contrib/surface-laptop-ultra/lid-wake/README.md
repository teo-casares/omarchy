# Surface Laptop Ultra closed-lid wake

The built-in keyboard and touchpad can wake the laptop from suspend-to-idle when pressure is applied to the closed laptop in a bag. The hook temporarily disables wake on the I²C keyboard (`MSHW0794`) and touchpad (`MSHW0734`) if ACPI reports that the lid is closed. It restores the settings it changed when the same systemd sleep service invocation resumes, even if the lid has since opened. The lid and power button have their own wake controls.

On a Surface Laptop Ultra with both wake controls under `/sys/bus/i2c/devices/`, install the optional hook with:

```sh
sudo install -Dm755 n1x-lid-wake /usr/lib/systemd/system-sleep/n1x-lid-wake
```

Run `bash test/shell.d/surface-hardware-test.sh` from the repository root to check the hook against simulated ACPI and sysfs files.
