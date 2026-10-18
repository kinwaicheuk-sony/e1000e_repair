#!/usr/bin/env bash
set -Eeuo pipefail

# Intel I219-V [8086:15b8] NVM checksum bypass for Ubuntu 22.04 HWE 6.8.
# Only tested on kernel 6.8.0-138-generic. Run with working backup networking.
# v9: install the exact kernel compiler and check it before building.
# Refresh APT indexes after enabling deb-src, even if entries already exist.

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
trap 'echo "Installation failed at line $LINENO. Original in-tree module was not overwritten." >&2' ERR

[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail 'Cannot identify operating system'
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 ]] || fail 'Only Ubuntu 22.04 is supported'
KERNEL=$(uname -r)
if [[ "$KERNEL" == '6.8.0-138-generic' ]]; then
  info "Running on tested kernel: $KERNEL"
elif [[ "$KERNEL" == '6.8.0-40-generic' ]]; then
  echo >&2 '============================================================'
  echo >&2 'WARNING: UNTESTED KERNEL 6.8.0-40-generic' 
  echo >&2 'The checksum bypass was verified only on 6.8.0-138-generic.'
  echo >&2 'This installer will attempt to build for 6.8.0-40-generic.'
  echo >&2 'The repository may supply newer source than this old kernel.'
  echo >&2 'Build, module loading, or network operation may fail.'
  echo >&2 'Keep a working USB Ethernet adapter and a recovery kernel.'
  echo >&2 '============================================================'
  read -r -p 'Type YES to attempt installation on 6.8.0-40-generic: ' answer
  [[ "$answer" == YES ]] || fail 'Cancelled by user'
else
  fail "Unsupported kernel $KERNEL. Allowed: 6.8.0-138-generic (tested), 6.8.0-40-generic (experimental)."
fi
# Install prerequisites before checking for tools such as gcc and lspci.
# An existing USB Ethernet connection (or other working internet) is required.
command -v apt-get >/dev/null || fail 'apt-get missing'
info 'Installing build tools and required packages (internet required)'
if ! apt-get update; then
  fail 'apt-get update failed. Check internet, system clock, and Ubuntu repositories.'
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential gcc-12 g++-12 "linux-headers-$KERNEL" dpkg-dev \
  pciutils kmod binutils python3 mokutil shim-signed initramfs-tools; then
  fail "Dependency installation failed. Check connectivity, clock, and availability of headers for $KERNEL."
fi
for tool in lspci python3 mokutil update-initramfs gcc-12 make modinfo depmod; do
  command -v "$tool" >/dev/null || fail "Missing required tool after installation: $tool"
done
[[ -d "/lib/modules/$KERNEL/build" ]] || fail "Kernel headers missing for $KERNEL"
# Ubuntu's 6.8 HWE kernels were built with gcc-12. The generic gcc
# command may point to a different version or may not be installed.
# Set CC explicitly so the kernel build system uses the right compiler.
KERNEL_COMPILER=gcc-12
if ! "$KERNEL_COMPILER" -dumpversion >/dev/null 2>&1; then
  fail "Kernel compiler $KERNEL_COMPILER is not working after dependency installation"
fi
info "Using kernel compiler: $($KERNEL_COMPILER --version | head -1)"

PCI=$(lspci -Dnns 00:1f.6 2>/dev/null || true)
[[ "$PCI" == *'[8086:15b8]'* ]] || fail "Unexpected Ethernet controller at 00:1f.6: $PCI"
if ! dmesg | grep -q 'The NVM Checksum Is Not Valid'; then
  echo 'WARNING: No original NVM checksum failure found in current boot log.'
  read -r -p 'You has confirmed this exact issue on this PC? Type YES to continue: ' answer
  [[ "$answer" == YES ]] || fail 'Cancelled'
fi

info 'Checking Secure Boot signing key'
SB_STATE=$(mokutil --sb-state 2>&1 || true)
SB_ENABLED=0
if [[ "$SB_STATE" == *'SecureBoot enabled'* ]]; then
  SB_ENABLED=1
  KEY=/var/lib/shim-signed/mok/MOK.priv
  CERT=/var/lib/shim-signed/mok/MOK.der

  # Each machine creates and enrolls its own key. Never distribute MOK.priv.
  if [[ ! -s "$KEY" || ! -s "$CERT" ]]; then
    info 'Secure Boot key is missing; generating a local MOK key'
    command -v update-secureboot-policy >/dev/null || fail 'update-secureboot-policy unavailable (shim-signed package)'
    if [[ -e "$KEY" || -e "$CERT" ]]; then
      fail 'Only one MOK file exists (incomplete key pair). Contact someone; do not overwrite an existing private key.'
    fi
    update-secureboot-policy --new-key || fail 'Could not generate MOK key. Contact someone.'
    [[ -s "$KEY" && -s "$CERT" ]] || fail 'MOK key generation did not create both files. Contact someone.'
  fi

  TEST_RESULT=$(mokutil --test-key "$CERT" 2>&1 || true)
  echo "$TEST_RESULT"
  if [[ "$TEST_RESULT" != *'already enrolled'* ]]; then
    echo
    echo '============================================================'
    echo 'ACTION REQUIRED: SECURE BOOT KEY ENROLLMENT'
    echo 'A signing key exists but has not been enrolled.'
    echo 'You will be prompted for a TEMPORARY enrollment password.'
    echo 'Choose a password you can enter again at the blue MOK screen.'
    echo '============================================================'

    # Ubuntu update-secureboot-policy --enroll-key can return without
    # queuing an import (for example in some Secure Boot states).
    # Use mokutil directly and VERIFY that the request was queued.
    if [[ ! -t 0 ]]; then
      fail 'Interactive terminal required for MOK password entry. Run: sudo bash install.sh in a terminal.'
    fi
    if ! mokutil --import "$CERT"; then
      fail 'mokutil could not request MOK enrollment. No driver installed.'
    fi
    PENDING=$(mokutil --list-new 2>&1 || true)
    if [[ -z "${PENDING//[[:space:]]/}" ]] || ! printf '%s' "$PENDING" | grep -qiE 'subject:|issuer:|sha1 fingerprint:|sha256 fingerprint:|certificate|serial number:'; then
      echo "$PENDING" >&2
      fail 'MOK enrollment was not confirmed as pending. Do NOT reboot expecting MOK Manager. Contact someone.'
    fi
    echo
    echo 'MOK enrollment request is pending:'
    printf '%s\n' "$PENDING" | head -30
    echo
    echo 'REBOOT REQUIRED: At the blue MOK Manager screen, choose:'
    echo '  Enroll MOK -> Continue -> Yes -> enter the password -> Reboot'
    echo 'After returning to Ubuntu, run: sudo bash install.sh'
    echo 'No driver was installed yet.'
    exit 0
  fi
fi

info 'Checking Ubuntu source repositories'
# apt-cache showsrc can fail if deb-src is disabled or if the Ubuntu
# mirror has no source indexes. Configure the same Ubuntu mirror already
# used for binary packages; do not silently switch to a public mirror.
if ! apt-cache showsrc linux-hwe-6.8 >/dev/null 2>&1; then
  info 'Source package not indexed; enabling deb-src on Ubuntu Jammy repositories'
  python3 - <<'PYAPT'
from pathlib import Path
import re

root = Path('/etc/apt')
files = [root / 'sources.list'] + sorted((root / 'sources.list.d').glob('*.list')) + sorted((root / 'sources.list.d').glob('*.sources'))
jammy = re.compile(r'^jammy(?:-(?:updates|security|backports|proposed))?$')
changed = 0
for path in files:
    if not path.is_file():
        continue
    original = path.read_text()
    if path.suffix == '.sources':
        # Parse deb822 stanzas, retaining all mirror-specific settings.
        blocks = re.split(r'(\n[ \t]*\n)', original)
        for i in range(0, len(blocks), 2):
            block = blocks[i]
            fields = dict((m.group(1).lower(), m.group(2).strip()) for m in re.finditer(r'(?m)^([A-Za-z-]+):[ \t]*(.*)$', block))
            if fields.get('enabled', 'yes').lower() == 'no':
                continue
            suites = fields.get('suites', '').split()
            types = fields.get('types', '').split()
            if 'deb' not in types or 'deb-src' in types or not any(jammy.fullmatch(x) for x in suites):
                continue
            blocks[i] = re.sub(r'(?m)^(Types:[ \t]*)(.*)$', lambda m: m.group(1) + m.group(2).rstrip() + ' deb-src', block, count=1)
        updated = ''.join(blocks)
    else:
        lines = original.splitlines(keepends=True)
        new_lines = []
        existing = {x.strip() for x in lines}
        for line in lines:
            new_lines.append(line)
            m = re.match(r'^(\s*)deb\s+(.*)$', line)
            if not m or line.lstrip().startswith('#'):
                continue
            rest = m.group(2).strip()
            # APT one-line syntax: deb [options] URI suite components...
            tokens = rest.split()
            if tokens and tokens[0].startswith('['):
                try:
                    closing = tokens.index(next(t for t in tokens if t.endswith(']')))
                    tokens = tokens[closing+1:]
                except StopIteration:
                    continue
            if len(tokens) < 3 or not jammy.fullmatch(tokens[1]):
                continue
            candidate = f'{m.group(1)}deb-src {rest}'
            if candidate.strip() not in existing:
                new_lines.append(candidate + '\n')
                existing.add(candidate.strip())
        updated = ''.join(new_lines)
    if updated != original:
        backup = path.with_name(path.name + '.e1000e-backup')
        if not backup.exists():
            backup.write_text(original)
        path.write_text(updated)
        changed += 1
        print(f'Enabled Ubuntu source packages: {path} (backup: {backup})')
print(f'Changed {changed} APT source configuration file(s).')
PYAPT
fi
# Even when deb-src entries are already present, source indexes may not
# have been downloaded yet. Always refresh before the final check.
info 'Refreshing APT indexes (including source indexes)'
if ! apt-get update; then
  fail 'APT update failed while retrieving source indexes. Check internet, system time, and your mirror.'
fi
if ! apt-cache showsrc linux-hwe-6.8 >/dev/null 2>&1; then
  echo 'Available Ubuntu source indexes:' >&2
  apt-cache showsrc linux 2>&1 | head -12 >&2 || true
  echo 'Active source repository entries:' >&2
  grep -RhE '^[[:space:]]*deb-src[[:space:]]|^[[:space:]]*Types:.*deb-src|^[[:space:]]*Suites:' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -35 >&2 || true
  fail 'linux-hwe-6.8 source is unavailable from the configured mirror. Ask someone to enable its Jammy source packages; no driver changes were made.'
fi
WORKDIR="/var/tmp/e1000e-repair-$KERNEL"
mkdir -p "$WORKDIR"
chmod 755 "$WORKDIR"
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
make -C "/lib/modules/$KERNEL/build" M="$PWD" CC="$KERNEL_COMPILER" modules -j"$(nproc)"
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
