# Surface Laptop Ultra sensor hub interrupt

The Surface Laptop Ultra's ACPI namespace describes the MSFW1111 SPI HID sensor hub at `\_SB.SENH`. Its falling-edge interrupt uses GIO0 offset 190. On Omarchy's 7.3.0-47 kernel, GIO0 is the MT8901 pin controller and exports offsets 0–181. The GPIO lookup fails before the SPI HID driver can request its interrupt. The MT8901 hardware routing table already maps EINT 190 to instance 3, index 9.

This candidate adds virtual descriptors for the existing internal EINTs 182–208. They use the MediaTek interrupt-only convention, with a fixed input direction and no physical pad settings. The first 182 descriptors retain their original numbering.

Apply the patch to a private kernel build tree. The target is Linux 7.3 prepared using the [Omarchy ARM64 kernel recipe at 376292460383](https://github.com/omacom/omarchy-pkgs/blob/3762924603830cf05fd4a795a0c9242389125065/pkgbuilds/linux-omarchy-aarch64/PKGBUILD), which produced the installed 7.3.0-47 package. These are the pre-patch SHA-256 digests of the affected files from the build tree used to verify the patch.

```text
cb6a01d050be1c7270d06d3637a8c5aa931fe0128f9cf6c84f2fa3db4228bbe4  drivers/pinctrl/mediatek/pinctrl-mtk-mt8901.h
705f9b5f189c42a31cb349cbcc5a205027e801ad64bce41beeedb2d95154827d  drivers/pinctrl/mediatek/pinctrl-paris.c
```

From the configured target kernel source tree, substitute the path to this directory below.

```sh
git apply --check /path/to/sensor-eint/0001-pinctrl-mediatek-expose-mt8901-internal-eints.patch
git apply /path/to/sensor-eint/0001-pinctrl-mediatek-expose-mt8901-internal-eints.patch
make ARCH=arm64 drivers/pinctrl/mediatek/pinctrl-mt8901.o drivers/pinctrl/mediatek/pinctrl-paris.o
```

Offline verification covers the firmware's `_CRS` and `_DSM` responses, the static EINT mapping, and both affected ARM64 objects. A supervised hardware test still needs to verify the GPIO IRQ, SPI HID reset response, HID enumeration, and an illuminance channel with changing readings. Use those results to decide whether to package the ACPI SPI HID transport.
