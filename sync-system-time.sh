#!/usr/bin/env bash
# Ubuntu: try NTP, then offer interactive manual clock setting.
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo 'Run with: sudo bash sync-time-with-fallback.sh' >&2
  exit 1
fi

command -v timedatectl >/dev/null || { echo 'timedatectl is unavailable.' >&2; exit 1; }

echo 'Current clock:'
timedatectl status

echo
echo 'Enabling automatic NTP synchronization...'
if timedatectl set-ntp true; then
  if systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
    systemctl restart systemd-timesyncd.service || true
  fi
  for i in $(seq 1 20); do
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
      echo 'SUCCESS: Clock synchronized using NTP.'
      timedatectl status
      exit 0
    fi
    sleep 2
  done
fi

echo
echo 'WARNING: Automatic synchronization was not confirmed within 40 seconds.'
echo 'Manual time entry requires a reliable clock (e.g., a phone).'
read -r -p 'Set the clock manually? [y/N]: ' answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo 'Clock unchanged; automatic NTP remains configured where supported.'
  exit 1
fi

current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
echo "Current timezone: ${current_tz:-unknown}"
read -r -p 'Change timezone to Asia/Tokyo? [y/N]: ' change_tz
if [[ "$change_tz" =~ ^[Yy]$ ]]; then
  timedatectl set-timezone Asia/Tokyo
fi

echo 'Enter the current LOCAL date/time using a trusted clock.'
read -r -p 'YYYY-MM-DD HH:MM:SS: ' manual_time
if [[ ! "$manual_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  echo 'Invalid format; clock unchanged.' >&2
  exit 1
fi

# Reject invalid calendar dates and times before changing the clock.
if ! date -d "$manual_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null | grep -Fxq "$manual_time"; then
  echo 'Invalid date/time; clock unchanged.' >&2
  exit 1
fi

echo "About to set local time to: $manual_time"
read -r -p 'Confirm? [y/N]: ' confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo 'Cancelled; clock unchanged.'
  exit 1
fi

timedatectl set-ntp false
timedatectl set-time "$manual_time"
# Keep the hardware clock consistent when possible.
if command -v hwclock >/dev/null 2>&1; then
  hwclock --systohc || echo 'WARNING: Could not update hardware clock.' >&2
fi

echo 'SUCCESS: Clock set manually. Automatic NTP is disabled.'
timedatectl status
