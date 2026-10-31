#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run: sudo bash offline_fix.sh'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || fail 'Requires Ubuntu 22.04'
[[ $(uname -m) == x86_64 ]] || fail 'Requires x86_64'
KERNEL=$(uname -r)
[[ -f kernel-version && -f SHA256SUMS ]] || fail 'Run the copy inside the generated bundle.'
[[ $(cat kernel-version) == "$KERNEL" ]] || fail "Bundle does not match running kernel $KERNEL"
sha256sum --check SHA256SUMS || fail 'Bundle integrity check failed'
DEV=/sys/bus/pci/devices/0000:00:1f.6
[[ -r $DEV/vendor && -r $DEV/device ]] || fail 'Expected PCI controller missing'
[[ $(cat "$DEV/vendor") == 0x8086 && $(cat "$DEV/device") == 0x15b8 ]] || fail 'Unexpected Ethernet controller'
LOG=$(dmesg)
if [[ $LOG != *'The NVM Checksum Is Not Valid'* && $LOG != *'NVM checksum invalid; continuing for diagnostic test'* ]]; then
  read -r -p 'Checksum failure absent from boot log. Previously confirmed this exact issue? Type YES: ' answer
  [[ ${answer^^} == YES ]] || fail 'Cancelled'
fi
# Use the target's installed tools. Installing the entire dependency archive
# can upgrade libc/systemd and require packages absent from the bundle.
# Never run a package manager on the offline target.
MISSING=()
for tool in modinfo depmod update-initramfs; do
  command -v "$tool" >/dev/null || MISSING+=("$tool")
done
if [[ -d /sys/firmware/efi ]]; then
  command -v mokutil >/dev/null || MISSING+=(mokutil)
fi
((${#MISSING[@]} == 0)) || fail "Missing required tools: ${MISSING[*]}. No packages or driver were installed. Prepare these prerequisites for this target before retrying."

[[ $(modinfo -F vermagic ./e1000e.ko) == "$KERNEL "* ]] || fail 'Module vermagic mismatch'
STATE='Legacy BIOS'
if [[ -d /sys/firmware/efi ]]; then
STATE=$(mokutil --sb-state 2>&1) || {
  [[ ! -d /sys/firmware/efi ]] || fail "Cannot determine Secure Boot state: $STATE"
  STATE='Legacy BIOS'
}
fi
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cp e1000e.ko "$TMP/e1000e.ko"
if [[ $STATE == *'SecureBoot enabled'* ]]; then
  command -v openssl >/dev/null || fail 'Secure Boot requires openssl; no driver installed.'

  KEYDIR=/var/lib/e1000e-repair
  KEY=$KEYDIR/MOK.priv
  CERT=$KEYDIR/MOK.der
  install -d -m 700 "$KEYDIR"
  if [[ ! -e $KEY && ! -e $CERT ]]; then
    (umask 077; openssl req -new -x509 -newkey rsa:2048 -nodes \
      -keyout "$KEY" -outform DER -out "$CERT" -days 3650 \
      -subj '/CN=e1000e offline repair/' -addext 'extendedKeyUsage=codeSigning')
  fi
  [[ -s $KEY && -s $CERT ]] || fail 'Incomplete local signing key pair; do not overwrite it.'
  if ! mokutil --test-key "$CERT"; then
    [[ -t 0 ]] || fail 'Interactive terminal required for MOK enrollment'
    mokutil --import "$CERT"
    mokutil --list-new
    echo 'Enrollment requested. Reboot, select Enroll MOK, enter your password,'
    echo 'then return to Ubuntu and run this offline installer again. No driver installed yet.'
    exit 0
  fi
  ./sign-file sha256 "$KEY" "$CERT" "$TMP/e1000e.ko"
  [[ -n $(modinfo -F signer "$TMP/e1000e.ko") ]] || fail 'Module signature missing'
elif [[ $STATE != *'SecureBoot disabled'* && $STATE != 'Legacy BIOS' ]]; then
  fail "Unrecognized Secure Boot state: $STATE"
fi
TARGET="/lib/modules/$KERNEL/updates/e1000e.ko"
if [[ -e $TARGET ]]; then
  cp -a "$TARGET" "$TARGET.backup.$(date +%Y%m%d%H%M%S)"
fi
install -D -m 644 "$TMP/e1000e.ko" "$TARGET"
depmod -a "$KERNEL"
[[ $(modinfo -n e1000e) == "$TARGET" ]] || fail 'Patched module not selected'
update-initramfs -u -k "$KERNEL"
echo 'Installed. Reboot, then check: modinfo -n e1000e; ip -br addr'
echo 'Rollback (original Ubuntu module remains intact):'
printf 'sudo rm -f %q\nsudo depmod -a %q\nsudo update-initramfs -u -k %q\nsudo reboot\n' "$TARGET" "$KERNEL" "$KERNEL"
