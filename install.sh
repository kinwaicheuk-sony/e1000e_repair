#!/usr/bin/env bash
set -Eeuo pipefail

# Intel I219-V [8086:15b8] NVM checksum bypass for Ubuntu 22.04 HWE 6.8.
# Only tested on kernel 6.8.0-138-generic. Run with working backup networking.

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
trap 'echo "Installation failed at line $LINENO. Original in-tree module was not overwritten." >&2' ERR

[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail 'Cannot identify operating system'
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || fail 'Only Ubuntu 22.04 is supported'
KERNEL=$(uname -r)
[[ "$KERNEL" == '6.8.0-138-generic' ]] || fail "Untested kernel $KERNEL (expected 6.8.0-138-generic). Contact IT."
command -v lspci >/dev/null || fail 'Missing lspci (install pciutils)'
PCI=$(lspci -Dnns 00:1f.6 2>/dev/null || true)
[[ "$PCI" == *'[8086:15b8]'* ]] || fail "Unexpected Ethernet controller at 00:1f.6: $PCI"
if ! dmesg | grep -q 'The NVM Checksum Is Not Valid'; then
  echo 'WARNING: No original NVM checksum failure found in current boot log.'
  read -r -p 'IT has confirmed this exact issue on this PC? Type YES to continue: ' answer
  [[ "$answer" == YES ]] || fail 'Cancelled'
fi
[[ -d "/lib/modules/$KERNEL/build" ]] || fail 'Kernel headers missing'
command -v apt-get >/dev/null || fail 'apt-get missing'
command -v apt >/dev/null || fail 'apt missing'
command -v python3 >/dev/null || fail 'python3 missing'
command -v mokutil >/dev/null || fail 'mokutil missing'
command -v update-initramfs >/dev/null || fail 'update-initramfs missing'
command -v gcc >/dev/null || fail 'gcc missing'
command -v make >/dev/null || fail 'make missing'

info 'Checking Secure Boot signing key'
SB_STATE=$(mokutil --sb-state 2>&1 || true)
SB_ENABLED=0
if [[ "$SB_STATE" == *'SecureBoot enabled'* ]]; then
  SB_ENABLED=1
  KEY=/var/lib/shim-signed/mok/MOK.priv
  CERT=/var/lib/shim-signed/mok/MOK.der
  [[ -s "$KEY" && -s "$CERT" ]] || fail 'Secure Boot enabled but MOK signing key missing. Contact IT.'
  TEST_RESULT=$(mokutil --test-key "$CERT" 2>&1 || true)
  echo "$TEST_RESULT"
  [[ "$TEST_RESULT" == *'already enrolled'* ]] || fail 'MOK certificate not enrolled. Enroll it first, reboot, then retry.'
fi

info 'Checking source repositories'
if ! apt-cache showsrc linux-hwe-6.8 >/dev/null 2>&1; then
  fail 'Ubuntu source repositories (deb-src) are not enabled. Contact IT.'
fi

WORKDIR="/var/tmp/e1000e-repair-$KERNEL"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
info 'Downloading Ubuntu HWE kernel source'
if ! compgen -G 'linux-hwe-6.8-*/drivers/net/ethernet/intel/e1000e/netdev.c' >/dev/null; then
  apt-get source linux-hwe-6.8
fi
SOURCE_FILE=$(find "$WORKDIR" -maxdepth 8 -path '*/drivers/net/ethernet/intel/e1000e/netdev.c' -print -quit)
[[ -n "$SOURCE_FILE" ]] || fail 'Could not find e1000e/netdev.c in downloaded source'
DRIVER_DIR=$(dirname "$SOURCE_FILE")
cd "$DRIVER_DIR"

info 'Applying exact checksum-bypass patch'
python3 - <<'PY'
from pathlib import Path
import re
p = Path('netdev.c')
s = p.read_text()
pattern = re.compile(
    r'(?P<indent>^[ \t]*)for \(i = 0;; i\+\+\) \{\s*'
    r'if \(e1000_validate_nvm_checksum\(&adapter->hw\) >= 0\)\s*break;\s*'
    r'if \(i == 2\) \{\s*'
    r'dev_err\(&pdev->dev, "The NVM Checksum Is Not Valid\\n"\);\s*'
    r'err = -EIO;\s*goto err_eeprom;\s*\}\s*\}', re.MULTILINE)
replacement = (
    'for (i = 0;; i++) {\n'
    '    if (e1000_validate_nvm_checksum(&adapter->hw) >= 0)\n'
    '        break;\n'
    '    if (i == 2) {\n'
    '        dev_warn(&pdev->dev,\n'
    '                 "NVM checksum invalid; continuing for diagnostic test\\n");\n'
    '        break;\n'
    '    }\n'
    '}')
match = pattern.search(s)
if match:
    Path('netdev.c.original').write_text(s)
    indent = match.group('indent')
    new = '\n'.join(indent + line for line in replacement.splitlines())
    p.write_text(s[:match.start()] + new + s[match.end():])
elif 'NVM checksum invalid; continuing for diagnostic test' in s:
    print('Source is already patched')
else:
    raise SystemExit('Expected kernel source code not found. Aborting rather than patching an unknown version.')
PY

cat > Makefile <<'MAKEFILE'
obj-m += e1000e.o
e1000e-y := 82571.o ich8lan.o 80003es2lan.o \
            mac.o manage.o nvm.o phy.o \
            param.o ethtool.o netdev.o ptp.o
ccflags-y += -I$(src)
MAKEFILE

info 'Building driver'
make -C "/lib/modules/$KERNEL/build" M="$PWD" modules -j"$(nproc)"
[[ -s e1000e.ko ]] || fail 'Driver module not created'
VERMAGIC=$(modinfo -F vermagic ./e1000e.ko)
[[ "$VERMAGIC" == "$KERNEL "* ]] || fail "Module kernel mismatch: $VERMAGIC"

if (( SB_ENABLED )); then
  info 'Signing module with this PC MOK key'
  "/lib/modules/$KERNEL/build/scripts/sign-file" sha256 "$KEY" "$CERT" ./e1000e.ko
  [[ -n "$(modinfo -F signer ./e1000e.ko)" ]] || fail 'Module signature missing'
fi

info 'Installing module without replacing Ubuntu original'
TARGET="/lib/modules/$KERNEL/updates/e1000e.ko"
if [[ -e "$TARGET" ]]; then
  cp -a "$TARGET" "$TARGET.backup.$(date +%Y%m%d%H%M%S)"
fi
install -D -m 644 ./e1000e.ko "$TARGET"
depmod -a "$KERNEL"
SELECTED=$(modinfo -n e1000e)
[[ "$SELECTED" == "$TARGET" ]] || fail "Module not selected: $SELECTED"

info 'Updating initramfs'
update-initramfs -u -k "$KERNEL"
info 'Completed. Reboot and run: sudo dmesg | grep -i e1000e; ip -br addr'
echo 'Expected: NVM checksum invalid; continuing for diagnostic test'
echo 'Rollback: sudo rm /lib/modules/$(uname -r)/updates/e1000e.ko && sudo depmod -a && sudo update-initramfs -u -k $(uname -r) && sudo reboot'
