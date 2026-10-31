#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
if [[ ${1:-} != --container-build ]]; then
  [[ $# -ge 1 && $# -le 2 ]] || fail 'Usage: bash build_offline_fix.sh TARGET_KERNEL [OUTPUT_DIRECTORY]'
  [[ $1 =~ ^6\.8\.0-[0-9]+-generic$ ]] || fail 'Expected Ubuntu 6.8.0-N-generic kernel from uname -r on the offline PC'
  command -v docker >/dev/null || fail 'Install Docker and start its daemon first.'
  ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  OUT=${2:-"$PWD/offline-bundle-$1"}
  [[ ! -e $OUT ]] || fail 'Output path already exists; choose a new directory.'
  mkdir -p -- "$OUT"
  OUT=$(cd -- "$OUT" && pwd)
  NETWORK_ARGS=(--network "${DOCKER_NETWORK:-host}")
  if [[ -n ${DOCKER_DNS:-} ]]; then
    NETWORK_ARGS+=(--dns "$DOCKER_DNS")
  fi
  docker run --rm --platform linux/amd64 "${NETWORK_ARGS[@]}" \
    -v "$ROOT:/repo:ro" -v "$OUT:/out" ubuntu:22.04 \
    bash /repo/build_offline_fix.sh --container-build "$1"
  echo "Copy the entire directory to the offline PC: $OUT"
  exit 0
fi
KERNEL=${2:?Missing target kernel}
export DEBIAN_FRONTEND=noninteractive
apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 update
apt-get install -y build-essential gcc-12 g++-12 "linux-headers-$KERNEL" dpkg-dev python3 kmod ca-certificates
KERNEL_COMPILER=gcc-12
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
if ! apt-get -o APT::Update::Error-Mode=any -o Acquire::Retries=2 update; then
  fail 'APT update failed while retrieving source indexes. Check internet, system time, and your mirror.'
fi
if ! apt-cache showsrc linux-hwe-6.8 >/dev/null 2>&1; then
  echo 'Available Ubuntu source indexes:' >&2
  apt-cache showsrc linux 2>&1 | head -12 >&2 || true
  echo 'Active source repository entries:' >&2
  grep -RhE '^[[:space:]]*deb-src[[:space:]]|^[[:space:]]*Types:.*deb-src|^[[:space:]]*Suites:' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -35 >&2 || true
  fail 'linux-hwe-6.8 source is unavailable from the configured mirror. Ask someone to enable its Jammy source packages; no driver changes were made.'
fi
WORKDIR="/tmp/e1000e-build-$KERNEL"
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


install -m 644 e1000e.ko /out/e1000e.ko
install -m 755 "/lib/modules/$KERNEL/build/scripts/sign-file" /out/sign-file
printf '%s\n' "$KERNEL" > /out/kernel-version
cp /repo/offline_fix.sh /out/offline_fix.sh
# Empty dpkg status forces download of dependencies even if installed here.
mkdir -p /out/packages/partial
: > /tmp/empty-status
apt-get -o Dir::State::status=/tmp/empty-status \
  -o Dir::Cache::archives=/out/packages --download-only --yes install \
  kmod mokutil openssl initramfs-tools pciutils libssl3
cd /out
sha256sum e1000e.ko sign-file kernel-version packages/*.deb > SHA256SUMS
chmod -R a+rX /out
info 'Offline bundle completed (unsigned module; keys stay on the target PC).'
