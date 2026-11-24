#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

(
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/bin" "$scratch/sys"
  touch "$scratch/sys/image_size" "$scratch/fstab"
  sed -e "s|/sys/power/|$scratch/sys/|g" \
    -e "s|\"/swap|\"$scratch/swap|g" \
    -e "s|/etc/mkinitcpio.conf.d|$scratch/mkinitcpio.conf.d|g" \
    -e "s|/etc/fstab|$scratch/fstab|g" \
    -e "s|/etc/limine-entry-tool.d|$scratch/limine-entry-tool.d|g" \
    "$ROOT/bin/omarchy-hibernation-setup" >"$scratch/setup"

  for command in omarchy-hw-aarch64-apple omarchy-sleep-disabled; do
    printf '#!/bin/bash\nexit 1\n' >"$scratch/bin/$command"
  done
  cat >"$scratch/bin/sudo" <<'SH'
#!/bin/bash
if [[ $* == *"btrfs filesystem show"* ]]; then
  printf '\tTotal devices %s FS bytes used 64.16MiB\n' "$DEVICE_COUNT"
  exit 0
fi
printf '%s\n' "$*" >>"$MUTATIONS"
exit 1
SH
  chmod +x "$scratch/bin/"*
  # Factory reset invokes setup this way after removing stale resume drop-ins
  # when the swapfile is missing, with the swapfile's fstab entry still present.
  printf '%s none swap defaults,pri=0 0 0\n' "$scratch/swap/swapfile" >"$scratch/fstab"
  if env PATH="$scratch/bin:$PATH" DEVICE_COUNT=2 MUTATIONS="$scratch/mutations" \
    bash "$scratch/setup" --force --no-rebuild >"$scratch/out" 2>&1; then
    fail "setup rejects a multi-device Btrfs swap filesystem"
  fi
  grep -Fq "multi-device Btrfs" "$scratch/out" ||
    fail "setup explains the resume-device ambiguity" "$(<"$scratch/out")"
  [[ ! -e $scratch/mutations && ! -e $scratch/swap && ! -e $scratch/mkinitcpio.conf.d &&
     ! -e $scratch/limine-entry-tool.d ]] ||
    fail "factory reset's setup call fails before creating swap or resume configuration"
  pass "factory reset's setup call fails before creating swap or resume configuration"

  factory_root=$scratch/factory
  mkdir -p "$factory_root"/{etc/mkinitcpio.conf.d,etc/limine-entry-tool.d,usr/bin,swap}
  touch "$scratch/esp" "$factory_root/etc/mkinitcpio.conf.d/omarchy_resume.conf" \
    "$factory_root/etc/limine-entry-tool.d/resume.conf" "$factory_root/usr/bin/omarchy-hibernation-setup"
  chmod +x "$factory_root/usr/bin/omarchy-hibernation-setup"
  printf '%s /boot vfat defaults 0 0\n/swap/swapfile none swap defaults 0 0\n' \
    "$scratch/esp" >"$factory_root/etc/fstab"

  eval "$(sed -n '/^rebuild_next_boot() {$/,/^}$/p' "$ROOT/bin/omarchy-system-factory-reset")"
  if (
    LOG_FILE=$scratch/factory-log
    reset_boot_owner() { RESET_BOOT=limine; }
    mount() { :; }
    btrfs() { return 1; }
    log() { :; }
    fail() { printf '%s\n' "$*"; exit 1; }
    reset_limine_config() { touch "$scratch/boot-files-changed"; }
    chroot() {
      [[ $4 == "/usr/bin/omarchy-hibernation-setup" ]] || return 1
      shift 4
      env PATH="$scratch/bin:$PATH" DEVICE_COUNT=2 MUTATIONS="$scratch/mutations" bash "$scratch/setup" "$@"
    }
    rebuild_next_boot "$factory_root"
  ) >"$scratch/factory-out" 2>&1; then
    fail "factory reset halts when setup cannot determine the resume device"
  fi
  grep -Fq "hibernation setup failed in the factory root" "$scratch/factory-out" &&
    grep -Fq "multi-device Btrfs" "$scratch/factory-log" &&
    [[ ! -e $scratch/boot-files-changed && ! -e $scratch/mutations ]] ||
    fail "factory reset stops before rebuilding boot files" "$(<"$scratch/factory-out")"
  pass "factory reset stops before rebuilding boot files for an ambiguous resume device"

  mkdir "$scratch/mkinitcpio.conf.d" "$scratch/limine-entry-tool.d" "$scratch/swap"
  touch "$scratch/swap/swapfile"
  printf 'HOOKS+=(resume)\n' >"$scratch/mkinitcpio.conf.d/omarchy_resume.conf"
  resume_conf=$scratch/limine-entry-tool.d/resume.conf

  for line in 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=4242"' \
              'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/custom resume_offset=6192 no_console_suspend"'; do
    printf '%s\n' "$line" >"$resume_conf"
    env PATH="$scratch/bin:$PATH" DEVICE_COUNT=2 MUTATIONS="$scratch/mutations" \
      bash "$scratch/setup" --force --no-rebuild >"$scratch/out" 2>&1 ||
      fail "setup accepts existing multi-device resume configuration" "$(<"$scratch/out")"
    grep -Fq "already set up" "$scratch/out" &&
      [[ ! -e $scratch/mutations && $(<"$resume_conf") == "$line" ]] ||
      fail "setup preserves existing multi-device resume configuration" "$(<"$scratch/out")"
  done
  pass "setup preserves fully configured and custom multi-device resume entries"

  incomplete='KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset="'
  printf '%s\n' "$incomplete" >"$resume_conf"
  if env PATH="$scratch/bin:$PATH" DEVICE_COUNT=2 MUTATIONS="$scratch/mutations" \
    bash "$scratch/setup" --force --no-rebuild >"$scratch/out" 2>&1; then
    fail "setup rejects ambiguous multi-device offset repair"
  fi
  grep -Fq "multi-device Btrfs" "$scratch/out" &&
    [[ ! -e $scratch/mutations && $(<"$resume_conf") == "$incomplete" ]] ||
    fail "setup rejects ambiguous repair before mapping or changing the offset" "$(<"$scratch/out")"
  pass "setup rejects ambiguous repair before mapping or changing the offset"
)

if [[ ! -f /sys/power/image_size ]]; then
  skip "hibernation is unavailable; skipping setup prompt test"
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat >"$tmpdir/bin/omarchy-cmd-missing" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$tmpdir/bin/grep" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$tmpdir/bin/free" <<'EOF'
#!/bin/bash
if [[ ${LC_ALL:-} == "C" ]]; then
  printf 'Mem: 31Gi 1Gi 30Gi\n'
else
  printf '内存： 31Gi 1Gi 30Gi\n'
fi
EOF

cat >"$tmpdir/bin/gum" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$PROMPT_LOG"
exit 1
EOF

chmod +x "$tmpdir/bin/"*

env -u LC_ALL PROMPT_LOG="$tmpdir/prompt" PATH="$tmpdir/bin:$PATH" \
  "$ROOT/bin/omarchy-hibernation-setup"

[[ $(<"$tmpdir/prompt") == "confirm Use 31Gi on boot drive to make hibernation available?" ]] ||
  fail "hibernation setup reads memory size independently of the user's locale"
pass "hibernation setup reads memory size independently of the user's locale"
