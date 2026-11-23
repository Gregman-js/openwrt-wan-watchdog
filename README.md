# openwrt-wan-watchdog

**WAN failover watchdog for OpenWrt** — two ping probes pinned per-uplink, metric-only
"route surgery" between a primary uplink and an LTE/USB backup. No mwan3, no extra
firewall framework, netifd-proof state re-assert, procd service, sysupgrade-safe.

Tested in production on: **OpenWrt 25.12.6, NanoPi R6C (rockchip/armv8)** — primary
DOCSIS uplink + LTE USB backup.

---

## Why another watchdog?

Because the naive ones break in ways that only show up during a real outage:

1. **`ifdown`/`ifup` watchdogs have a chicken-and-egg flaw.** Once the primary
   interface is down, there is nothing left to probe — you cannot detect *recovery*.
   This project never touches the interface: it operates **only on routes**
   (hence "route surgery"), so the WAN interface, its DHCP lease and its probe
   path stay alive in every state.

2. **An interface with carrier up can still have no internet.** A single
   health check answers "is the link alive", not "does the internet work".

3. **Two writers, one routing table.** netifd re-installs uci-configured routes on
   events (DHCP renew every few hours, reloads, carrier flaps) — a one-shot metric
   change gets silently reverted mid-outage. This watchdog **re-asserts its state
   every cycle** with idempotent `ip route replace` calls.

## How it works

```
                    ┌────────── PROBE (every 10 s) ───────────┐
                    │  ping 9.9.9.9   (pinned /32 -> WAN)      │
                    │  ping 1.0.0.1   (pinned /32 -> LTE)      │
                    └───────────────────┬─────────────────────┘
                                        │
        ┌───────────────────────────────┴───────────────────────┐
        │ STATE "wan" (normal)                                   │
        │ default: wan(metric 10) beats LTE(metric 20)           │
        │ 3 consecutive probe failures -> FAILOVER               │
        └───────────────────────────────┬───────────────────────┘
                                        │
        ┌───────────────────────────────┴───────────────────────┐
        │ STATE "lte" (failover)                                 │
        │ default: LTE(metric 5) beats wan(metric 10)            │
        │ wan interface STAYS UP (DHCP lease alive, probe works) │
        │ 2 consecutive probe successes -> FAILOVER OFF          │
        └───────────────────────────────────────────────────────┘
```

Key properties:

- **Failover only into a living backup** — if the LTE probe is also dead, the
  watchdog stays on WAN instead of jumping into a worse state.
- **Switching is a single-metric change**, done with atomic `ip route replace`
  (upsert) on the *backup* route only — the netifd-owned primary route is never
  touched, so DHCP renewals cannot undo a failover mid-outage.
- **Probes are pinned with /32 routes** (an unused public IP per uplink), so the
  primary link is probed continuously *even while traffic flows over LTE* — that
  is what makes automatic recovery detection possible.
- **Everything else is untouched**: firewall, DHCP, DNS chain, flow offloading,
  SQM — no capability games, no second firewall framework (looking at you, mwan3).

## What it does NOT do

- No load balancing / per-app policies (failover only). If you need those, use
  [mwan3](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3) — and
  remember it requires disabling flow offloading.
- No DNS handling — pair it with whatever resolver stack you run (tested with
  dnsmasq → AdGuard Home, works identically with dnsmasq → Blocky).

## Install

```bash
# 0. verify assumptions (read-only; add --deep to probe both uplinks):
sh wan-watchdog-verify.sh --deep

# 1. files
cp wan-watchdog       /usr/bin/wan-watchdog
cp wan-watchdog.initd /etc/init.d/wan-watchdog
chmod +x /usr/bin/wan-watchdog /etc/init.d/wan-watchdog

# 2. metrics (REQUIRED — unset metric means 0, and 5 < 0 is false)
uci set network.wan.metric='10'
uci set network.wan_usb.metric='20'
uci commit network
/etc/init.d/network reload

# 3. survive sysupgrade
echo /usr/bin/wan-watchdog >> /etc/sysupgrade.conf
echo /etc/init.d/wan-watchdog >> /etc/sysupgrade.conf

# 4. start
/etc/init.d/wan-watchdog enable
/etc/init.d/wan-watchdog start
logread | grep wan-watchdog
```

Full install + test playbook (including a blackhole-based outage simulation that
does not touch any cable): see `INSTALL.md`.

## Testing a logical (non-physical) outage

```bash
# kill only the probe path — the whole network keeps running:
ip route replace blackhole 9.9.9.9/32 metric 0
#   ~30 s -> "SONDA WAN fail x3, LTE ok -> FAILOVER na LTE" (logread)
ip route del blackhole 9.9.9.9/32
#   ~20 s -> "Netia zyje (sonda ok x2) -> POWROT na WAN"
```

## Files

| File | Purpose |
|---|---|
| `wan-watchdog` | the service script (procd-managed daemon loop) |
| `wan-watchdog.initd` | procd init wrapper (`respawn` = crash-proof) |
| `wan-watchdog-verify.sh` | pre-flight checks for every assumption; `--deep` also probes both uplinks through pinned routes (cleans up via trap) |
| `INSTALL.md` | step-by-step install + test playbook |

Tune at the top of `wan-watchdog`: interface names, probe targets, `FAIL_MAX`,
`OK_MIN`, sleep intervals (defaults: 3 fails × 10 s → failover, 2 oks × 10 s →
recover, 30 s probing interval while on LTE to save data quota).

## License

[MIT](LICENSE) — © 2026 Gregman-js
