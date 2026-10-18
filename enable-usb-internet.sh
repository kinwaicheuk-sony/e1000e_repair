#!/usr/bin/env bash
# Ubuntu: try NetworkManager first, fall back to ISC dhclient.
set -Eeuo pipefail

log() { printf '[usb-net] %s\n' "$*"; }
fail() { printf '[usb-net] ERROR: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run with sudo: sudo bash enable-usb-internet-with-time.sh [interface]'
command -v ip >/dev/null || fail 'iproute2 is required.'

is_usb_ethernet() {
    local iface="$1" path
    [[ -d "/sys/class/net/$iface" ]] || return 1
    [[ "$(cat "/sys/class/net/$iface/type" 2>/dev/null)" == 1 ]] || return 1
    path="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
    [[ "$path" == *'/usb'* ]] || [[ "$iface" == enx* || "$iface" == wwx* ]]
}

if [[ $# -gt 1 ]]; then fail 'Usage: sudo bash enable-usb-internet-with-time.sh [interface]'; fi
if [[ $# -eq 1 ]]; then
    IFACE="$1"
    is_usb_ethernet "$IFACE" || fail "'$IFACE' is not a detected USB Ethernet interface."
else
    mapfile -t CANDIDATES < <(for p in /sys/class/net/*; do i="${p##*/}"; if is_usb_ethernet "$i"; then printf '%s\n' "$i"; fi; done)
    ((${#CANDIDATES[@]})) || fail 'No USB Ethernet interface found. Plug in the adapter.'
    if ((${#CANDIDATES[@]} > 1)); then
        printf '[usb-net] Multiple USB Ethernet interfaces found: %s\n' "${CANDIDATES[*]}" >&2
        fail 'Specify one explicitly: sudo bash enable-usb-internet-with-time.sh INTERFACE'
    fi
    IFACE="${CANDIDATES[0]}"
fi
log "Using $IFACE"
ip link set dev "$IFACE" up

has_ipv4() { ip -4 -o addr show dev "$IFACE" scope global | grep -q ' inet '; }
has_default_route() { ip -4 route show default dev "$IFACE" | grep -q '^default '; }
check_internet() {
    has_ipv4 && has_default_route || return 1
    # Test internet reachability; ping may be blocked on some networks.
    ping -n -I "$IFACE" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}
show_status() {
    log 'IPv4 addresses:'
    ip -4 addr show dev "$IFACE"
    log 'Default route(s) on this interface:'
    ip -4 route show default dev "$IFACE"
}

# After networking, try NTP and offer manual time entry if it fails.
sync_clock() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    log 'WARNING: timedatectl unavailable; skipping time configuration.'
    return 0
  fi
  echo 'Current clock:'
  timedatectl status

  echo
  echo 'Enabling automatic NTP synchronization...'
  if timedatectl set-ntp true; then
    if systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
      systemctl restart systemd-timesyncd.service || true
    fi
    for i in $(seq 1 5); do
      if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
        echo 'SUCCESS: Clock synchronized using NTP.'
        timedatectl status
        return 0
      fi
      sleep 1
    done
  fi

  echo
  echo 'WARNING: Automatic synchronization was not confirmed within 5 seconds.'
  echo 'Manual time entry requires a reliable clock (e.g., a phone).'
  if [[ ! -t 0 ]]; then
    echo 'No interactive terminal available; skipping manual time entry.'
    return 1
  fi
  read -r -p 'Set the clock manually? [y/N]: ' answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo 'Clock unchanged; automatic NTP remains configured where supported.'
    return 1
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
    return 1
  fi

  # Reject invalid calendar dates and times before changing the clock.
  if ! date -d "$manual_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null | grep -Fxq "$manual_time"; then
    echo 'Invalid date/time; clock unchanged.' >&2
    return 1
  fi

  echo "About to set local time to: $manual_time"
  read -r -p 'Confirm? [y/N]: ' confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo 'Cancelled; clock unchanged.'
    return 1
  fi

  timedatectl set-ntp false
  timedatectl set-time "$manual_time"
  # Keep the hardware clock consistent when possible.
  if command -v hwclock >/dev/null 2>&1; then
    hwclock --systohc || echo 'WARNING: Could not update hardware clock.' >&2
  fi

  echo 'SUCCESS: Clock set manually. Automatic NTP is disabled.'
  timedatectl status
}

NM_ATTEMPTED=0
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f RUNNING general 2>/dev/null | grep -qx running; then
    NM_ATTEMPTED=1
    log 'Trying NetworkManager first (up to 5 seconds)...'
    nmcli device set "$IFACE" managed yes >/dev/null 2>&1 || true
    if timeout 5s nmcli --wait 2 device connect "$IFACE"; then
        if check_internet; then
            log 'SUCCESS: Internet works through NetworkManager.'
            show_status
            sync_clock || log "Time setting skipped; network remains configured."
            exit 0
        fi
        log 'NetworkManager connected, but internet test failed.'
    else
        log 'NetworkManager could not activate the connection.'
    fi
    log 'Switching this USB adapter to manual DHCP to prevent competing DHCP clients.'
    nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
    nmcli device set "$IFACE" managed no >/dev/null 2>&1 || true
fi

command -v dhclient >/dev/null 2>&1 || fail 'dhclient is not installed. Install isc-dhcp-client.'
# Clear any addresses/routes left by the failed NetworkManager attempt.
if ((NM_ATTEMPTED)); then
    ip -4 addr flush dev "$IFACE" scope global
fi
ip link set dev "$IFACE" up
log 'Requesting an IPv4 address with dhclient...'
if ! timeout 65s dhclient -1 -v "$IFACE"; then
    show_status
    fail 'DHCP failed. Check cable, switch port and DHCP server.'
fi
show_status
if check_internet; then
    log 'SUCCESS: Internet works through dhclient fallback.'
    sync_clock || log "Time setting skipped; network remains configured."
elif has_ipv4 && has_default_route; then
    log 'DHCP succeeded and a default route exists, but ping to 1.1.1.1 failed.'
    log 'ICMP may be blocked, or internet access may still be unavailable.'
    log 'Attempting NTP synchronization anyway...'
    sync_clock || log "Time setting skipped; network remains configured."
else
    fail 'DHCP did not provide both an IPv4 address and a default route.'
fi
