#!/bin/bash
# Installs adsb-watchdog and its systemd units. Run as root on the feeder:
#   sudo ./install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

echo "=== 1. backing up current watchdog ==="
if [ -f /usr/local/bin/adsb-watchdog ]; then
    cp -a /usr/local/bin/adsb-watchdog "/usr/local/bin/adsb-watchdog.bak-$TS"
    echo "  saved /usr/local/bin/adsb-watchdog.bak-$TS"
else
    echo "  none present"
fi

echo "=== 2. installing watchdog ==="
install -o root -g root -m 0755 "$SRC/bin/adsb-watchdog" /usr/local/bin/adsb-watchdog
bash -n /usr/local/bin/adsb-watchdog && echo "  syntax OK"

echo "=== 3. installing systemd units ==="
install -o root -g root -m 0644 "$SRC/systemd/adsb-watchdog.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SRC/systemd/adsb-watchdog.timer"   /etc/systemd/system/
echo "  adsb-watchdog.service, adsb-watchdog.timer"

echo "=== 4. installing drop-ins ==="
install -d -m 0755 /etc/systemd/system/readsb.service.d
install -o root -g root -m 0644 "$SRC/systemd/readsb.service.d/10-startlimit.conf" \
    /etc/systemd/system/readsb.service.d/10-startlimit.conf
echo "  readsb.service.d/10-startlimit.conf"

install -d -m 0755 /etc/systemd/system/flight-tracker.service.d
install -o root -g root -m 0644 "$SRC/systemd/flight-tracker.service.d/10-backoff.conf" \
    /etc/systemd/system/flight-tracker.service.d/10-backoff.conf
echo "  flight-tracker.service.d/10-backoff.conf"

echo "=== 5. state dirs ==="
install -d -m 0755 /var/lib/adsb-watchdog /run/adsb-watchdog
echo "  /var/lib/adsb-watchdog (persistent), /run/adsb-watchdog (tmpfs)"

echo "=== 6. reloading systemd ==="
systemctl daemon-reload
systemctl enable --now adsb-watchdog.timer >/dev/null 2>&1 || true

echo "=== 7. effective limits ==="
printf "  readsb         RestartSec=%s StartLimitBurst=%s StartLimitInterval=%s\n" \
    "$(systemctl show readsb -p RestartUSec --value)" \
    "$(systemctl show readsb -p StartLimitBurst --value)" \
    "$(systemctl show readsb -p StartLimitIntervalUSec --value)"
printf "  flight-tracker RestartSec=%s StartLimitBurst=%s StartLimitInterval=%s\n" \
    "$(systemctl show flight-tracker -p RestartUSec --value)" \
    "$(systemctl show flight-tracker -p StartLimitBurst --value)" \
    "$(systemctl show flight-tracker -p StartLimitIntervalUSec --value)"

echo "=== 8. first run (caches port location) ==="
/usr/local/bin/adsb-watchdog
echo "  cached port: $(cat /var/lib/adsb-watchdog/sdr_port 2>/dev/null || echo '<none>')"
echo "  cached hcd : $(cat /var/lib/adsb-watchdog/sdr_hcd 2>/dev/null || echo '<none>')"

echo
echo "DONE. Recent watchdog output:"
journalctl -t adsb-watchdog -n 10 --no-pager
