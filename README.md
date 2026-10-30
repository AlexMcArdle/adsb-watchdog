# adsb-watchdog

Watchdog for a Raspberry Pi 5 ADS-B / Flightradar24 feeder (`fr24-feeder`).

Keeps the RTL-SDR receive chain alive across the failure modes that actually
take this feeder down: the dongle dropping off the USB bus, the dongle
enumerating but wedging silently, and dependent services hot-looping when the
radio or the LED panel is unavailable.

## The stack it watches

| Service | Role |
| --- | --- |
| `readsb` | Decodes 1090 MHz from the RTL-SDR, serves Beast on `:30005` |
| `fr24feed` | Reads Beast from `readsb`, uploads to Flightradar24 |
| `flight-tracker` | Pushes the nearest aircraft to a CoolLED BLE panel |

Hardware: Raspberry Pi 5 (1 GB), Nooelec NESDR SMArt v5 (`0bda:2838`,
RTL2832U + R820T tuner).

## Recovery ladder

The watchdog runs once a minute via `adsb-watchdog.timer`.

| Symptom | Action | Cooldown |
| --- | --- | --- |
| Device present, `aircraft.json` stale > 90s | `usbreset` + restart `readsb` | 2 min |
| Device gone from the bus | Write `1`→`0` to the port's `disable` attribute — a kernel-level software replug | 3 min |
| Port cycle didn't recover it | Unbind/rebind the backing xHCI controller | 15 min |
| Still gone | Warn; needs a physical replug | — |

### Why `disable` and not `uhubctl`

A Pi 5 drives its USB-A ports from two xHCI controllers via RP1 and has no
per-port power switching, so `uhubctl` cannot cycle an individual port there.
The kernel does expose a writable `disable` attribute per root-hub port:

```
/sys/bus/usb/devices/<bus>-0:1.0/usb<bus>-port<n>/disable
```

Writing `1` then `0` drops and re-enumerates that port only — the same effect
as pulling the plug, without needing hands or extra packages.

### Port location is discovered, never hardcoded

The port is resolved from the device's own `busnum` + `devpath` whenever the
dongle is present, then persisted:

```
/var/lib/adsb-watchdog/sdr_port   # e.g. /sys/bus/usb/devices/3-0:1.0/usb3-port2
/var/lib/adsb-watchdog/sdr_hcd    # e.g. xhci-hcd.1
```

Persisting matters because once the dongle falls off the bus there is nothing
left to query — and a hardcoded port silently stops matching the moment the
dongle is moved to a different socket.

Devices behind an external hub have a dotted `devpath` (`2.1`) and are not
handled; only root-hub ports are cycled.

### Over-current monitoring

Each port exposes `over_current_count`. A non-zero value is the direct
signature of a power fault (undersized supply, unpowered hub, a dongle drawing
more than the port allows) and is surfaced as a warning rather than being
silently retried.

## systemd limits

Both drop-ins exist to stop a failure from turning into a restart storm on a
1 GB box.

- **`readsb.service.d/10-startlimit.conf`** — the packaged unit sets
  `StartLimitInterval=1` / `StartLimitBurst=100` in `[Service]`, which is both
  the legacy key name and the wrong section, so systemd ignores it; the
  observed effect was 24 restarts in ~6 minutes with no SDR attached. The
  drop-in sets real limits in `[Unit]` and raises `RestartSec` to 30s.
- **`flight-tracker.service.d/10-backoff.conf`** — `run_display.sh` exhausts 5
  BLE retries (~55s) and exits 1; with `RestartSec=10` that meant a restart
  roughly every 65s forever whenever the panel was off, and every start runs
  `ExecStartPre=systemctl restart bluetooth`. Now 3 attempts per 30 minutes.

The watchdog calls `systemctl reset-failed` before restarting, so systemd
giving up costs no recovery ability — the watchdog brings the unit back once
the underlying cause clears.

## Install

On the feeder:

```sh
git clone git@github.com:AlexMcArdle/adsb-watchdog.git
cd adsb-watchdog
sudo ./install.sh
```

Backs up any existing `/usr/local/bin/adsb-watchdog` to
`adsb-watchdog.bak-<timestamp>`, installs the units, enables the timer, and
does a first run to populate the cached port location.

This repo is the source of truth — deploy via `install.sh` rather than editing
the installed copy in place.

## Verifying

```sh
journalctl -t adsb-watchdog -f                  # watchdog decisions
systemctl list-timers adsb-watchdog.timer       # next run
cat /var/lib/adsb-watchdog/sdr_port             # discovered port
curl -s localhost:8754/monitor.json | jq .feed_status   # FR24 upload state
```

A healthy tick logs nothing. Warnings are the signal.

To exercise tier 2 deliberately (briefly interrupts the feed):

```sh
sudo sh -c 'echo 1 > /sys/bus/usb/devices/3-0:1.0/usb3-port2/disable'
```

The next tick should log the port cycle and bring `readsb` back.

