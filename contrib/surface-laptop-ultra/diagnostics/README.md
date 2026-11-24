# Surface Laptop Ultra boot and suspend diagnostics

These optional units capture evidence for intermittent NVIDIA startup failures on the ARM64 Surface Laptop Ultra. Files under this directory take effect only when an administrator installs and enables them. All collected data stays on the machine.

| Capture | Where to read it |
| --- | --- |
| The earliest matching NVIDIA, PCI, firmware-error and display events available when the boot collector runs, with kernel timestamps | `/var/log/surface-gpu-diagnostics/<boot-id>-first-probe.jsonl` |
| ACPI boot-error bytes, selected EFI error variables, firmware update status and firmware timing counters | `journalctl -b -u surface-boot-evidence.service` |
| Battery, thermal zone, watchdog and suspend counters before entry and when the suspend service returns, plus the first recorded wake IRQ when available | `journalctl -b -u systemd-suspend.service` |
| Btrfs root device error counters and selected cached NVMe health counters at boot, before suspend and when the suspend service returns | Entries beginning with `Storage snapshot` in either unit journal |
| EFI panic records when the kernel manages to write one | `/sys/fs/pstore/` or the archive configured for `systemd-pstore.service` |

The GPU collector samples the kernel journal without opening a GPU device. The tmpfiles configuration sets 14-day age-based cleanup on the root-only report directory and enables kernel suspend/resume callback timing messages where supported. Firmware slots can contain records from earlier boots. A pre-suspend entry without a return records the last observable service phase. The NVMe SMART update timestamp identifies the cached UDisks sample. Compare the sample time and cumulative counters across captures to establish when UDisks observed a change. A hard power loss can leave the firmware and kernel with no opportunity to write a final record. Review collected data locally before sharing it.

## Installation

Use this configuration on systems with systemd, a persistent journal, Bash and GNU coreutils. The platform-specific probes target NVIDIA at PCI address `000f:01:00.0`, battery `BAT1` and AC adapter `ADP1`. Missing optional sysfs fields are skipped. The storage collector uses btrfs-progs for the root filesystem and busctl, jq and UDisks2 for the NVMe controller behind `nvme0n1`. UDisks2 must expose the controller SMART interface for those fields to appear.

Copy the files using these destinations, creating any missing directories. Compare existing files first and save a copy of anything you replace. Install the shell collectors with mode `0755` and configuration files with mode `0644`, all owned by root.

| Source | Destination |
| --- | --- |
| Files under `system/` | Matching paths under `/etc/systemd/system/` |
| `lib/surface-storage-evidence` and `lib/surface-firmware-evidence` | Matching filenames under `/usr/local/lib/` |
| `tmpfiles.d/surface-gpu-evidence.conf` | `/etc/tmpfiles.d/surface-gpu-evidence.conf` |

For persistent EFI panic capture on an Arch mkinitcpio installation, the kernel must provide EFI pstore and the system must expose writable EFI variable storage. The optional `modprobe.d/70-efi-crash-records.conf` enables the EFI pstore backend. The optional `mkinitcpio.conf.d/04-surface-efi-pstore.conf` requests early module inclusion. Copy them under `/etc/modprobe.d/` and `/etc/mkinitcpio.conf.d/` respectively. Use the machine's normal initramfs or unified kernel image build procedure and verify the resulting image includes `efi_pstore` and its module options before using that image. Custom boot image pipelines may require additional integration.

Load and validate the systemd units, then start the two boot captures. This also makes them run on future boots.

```sh
sudo systemctl daemon-reload
systemd-analyze verify surface-boot-evidence.service surface-gpu-first-probe.service systemd-suspend.service
sudo systemctl enable --now surface-boot-evidence.service surface-gpu-first-probe.service
systemctl show -p Result surface-boot-evidence.service surface-gpu-first-probe.service
sudo journalctl -b -u surface-boot-evidence.service
```

The suspend drop-ins apply to the next normal systemd suspend. The install and verification commands leave the current power state alone. Use journal boot IDs to compare multiple incidents and `journalctl -b -1 -u systemd-suspend.service` for the previous session.

## Removal

Disable any boot units you enabled for this installation with `sudo systemctl disable surface-boot-evidence.service surface-gpu-first-probe.service`. Remove files you added, restore any files replaced during installation and run `sudo systemctl daemon-reload`. If you installed the optional early panic capture configuration, restore the previous module settings and rebuild the same boot image through its normal pipeline. Previously collected journal entries and reports follow their configured retention policy.

## Recovery across Surface firmware updates

Some custom GRUB installations load `n1x_carveout_memmap` in the initramfs. This helper assumes specific physical memory ranges. If the firmware changes the memory map, a recovery entry that blocks only the graphics drivers can still load the helper.

The optional `grub-recovery-carveout.patch` adds the helper to both module blacklists on menus where the text and fallback entries share `blacklist_args`. Before applying it, check that only the intended recovery entries reference this variable. Back up the active menu, apply the patch to a separate copy, run `grub-script-check` on that copy and inspect the diff before installing it. The kernel must receive the recovery entry's command line. A signed UKI with an embedded command line can ignore external arguments when Secure Boot is enabled.

Before updating, save the ACPI IORT table, the kernel's physical memory map, EFI boot entries and a copy of the working boot images. Verify a rescue medium can unlock the Linux storage. After Windows finishes the firmware update, choose a recovery entry that blocks the helper on the first Linux boot. Check `/proc/cmdline` and `/sys/module/n1x_carveout_memmap` to confirm the blacklist took effect. Compare the new GPU reserved ranges, their device associations and the RAM map against the helper's assumptions before returning to accelerated graphics.

Microsoft publishes firmware versions and release notes for this model. [Surface Laptop Ultra update history](https://support.microsoft.com/en-us/surface/updates/surface-laptop-ultra-update-history)

On the recovery boot, compare the saved pre-update captures with the current
kernel's IORT table and physical memory map. Run from this diagnostics directory
and substitute the paths to your saved binary IORT and unredacted `/proc/iomem`.

```bash
sudo ./lib/surface-gpu-carveout-compare before-IORT.bin before-iomem.txt \
  /sys/firmware/acpi/tables/IORT /proc/iomem
```

The tool defaults to the Surface GPU at `000f:01:00.0`. Verify the PCI address
with `lspci -Dn` in both captures. Use `--gpu` if the same GPU is at another
address in both boots. If enumeration changed between boots, review the
mapping manually.

The comparison derives the requester ID from the PCI address, resolves its
stream on the IORT SMMU, and selects RMR descriptors on that same SMMU whose
output stream ranges include the GPU stream. It reports inclusive physical
intervals and intersects them with the listed System RAM. It also checks both
hard-coded helper intervals separately, since the helper maps only part of the
lower RMR and skips another RMR entirely. For each helper interval it compares
the nearest RAM boundaries on either side and the addresses and names of other
overlapping resources. The output omits resource names and input file paths.

| Exit | Meaning |
| --- | --- |
| 0 | Both helper ranges have GPU RMR coverage and the selected mapping, RAM boundaries and overlapping resources agree |
| 1 | Selected evidence changed, or a helper interval intersects System RAM |
| 2 | Incomplete or unsupported evidence, including masked addresses or an unresolved requester |

This check covers direct PCI requester-to-SMMU mappings. DMA aliases,
runtime page ownership, EFI descriptors and memmap presence require independent
evidence. An exit of 0 only describes the compared captures. Keep the helper
blacklisted while investigating changed or unknown results.

The binary layout is documented in [Arm DEN0049](https://documentation-service.arm.com/static/68c159178a337a2bc6645aea?token=).
Linux uses the SMMU node and an inclusive output StreamID range to associate
RMR nodes with devices. [Linux IORT implementation](https://github.com/torvalds/linux/blob/master/drivers/acpi/arm64/iort.c)

## Graphical CPU fallback

Normal Omarchy tries NVIDIA first. On this Surface, a GPU initialization timeout has previously allowed Hyprland to start on the firmware framebuffer using Mesa llvmpipe. The optional `grub-recovery-cpu-desktop.patch` adds **Recovery → CPU desktop** to the custom GRUB menu described above. It uses the existing recovery blacklists and starts the graphical target. Apply it to a staged copy after the carveout patch, check the diff and run `grub-script-check`. Recovery highlights CPU desktop first. The main menu continues to highlight the normal Omarchy entry. If the kernel hangs completely, choose CPU desktop at the next boot.

To show a GPU warning on graphical login for SKU `Surface_Laptop_Ultra_2115`, install the two user files and enable the unit from the diagnostics directory.

```sh
install -Dm755 lib/surface-gpu-fallback-notice ~/.local/libexec/surface-gpu-fallback-notice
install -Dm644 user/surface-gpu-fallback-notice.service ~/.config/systemd/user/surface-gpu-fallback-notice.service
systemctl --user daemon-reload
systemctl --user enable --now surface-gpu-fallback-notice.service
```

The service uses Omarchy’s session renderer marker or its bundled renderer probe. A CPU session with a recorded NVIDIA initialization error shows a critical notification at login. A manually blacklisted GPU gets a separate informational message. A GPU-rendered session exits silently. The critical notification uses the default notify-send identity so Omarchy can display it during Do Not Disturb. The user journal records the message under `surface-gpu-fallback-notice.service`. To remove it, disable the user unit, delete these two files and reload the user manager.
