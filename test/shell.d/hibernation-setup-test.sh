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
  if env PATH="$scratch/bin:$PATH" DEVICE_COUNT=2 MUTATIONS="$scratch/mutations" \
    bash "$scratch/setup" --force --no-rebuild >"$scratch/out" 2>&1; then
    fail "setup rejects a multi-device Btrfs swap filesystem"
  fi
  grep -Fq "multi-device Btrfs" "$scratch/out" ||
    fail "setup explains the resume-device ambiguity" "$(<"$scratch/out")"
  [[ ! -e $scratch/mutations ]] ||
    fail "setup rejects multi-device Btrfs before trying to change system state"
  pass "setup rejects multi-device Btrfs before trying to change system state"

  mkdir "$scratch/mkinitcpio.conf.d" "$scratch/limine-entry-tool.d"
  printf 'HOOKS+=(resume)\n' >"$scratch/mkinitcpio.conf.d/omarchy_resume.conf"
  printf 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=4242"\n' >"$scratch/limine-entry-tool.d/resume.conf"
  env PATH="$scratch/bin:$PATH" DEVICE_COUNT=1 MUTATIONS="$scratch/mutations" \
    bash "$scratch/setup" --force --no-rebuild >"$scratch/out" 2>&1 ||
    fail "setup accepts existing single-device Btrfs configuration" "$(<"$scratch/out")"
  grep -Fq "already set up" "$scratch/out" && [[ ! -e $scratch/mutations ]] ||
    fail "setup preserves existing single-device Btrfs configuration" "$(<"$scratch/out")"
  pass "setup preserves existing single-device Btrfs configuration"
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
