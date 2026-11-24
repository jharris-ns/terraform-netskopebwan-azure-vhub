# Changelog

## 2026-11-24 — SSE Monitor: Upgrade-Survivable Deployment

### Problem

A BWAN upgrade from the Netskope console replaces the root filesystem (`/dev/sda2`); only `/infroot` (`/dev/sda4`) survives. The SSE monitor lived entirely on the wiped filesystem (`/root/sse_monitor/`, `/etc/systemd/system/sse_monitor.service`, `/etc/logrotate.d/sse_monitor`), so after an upgrade it was gone and the gateway advertised `0.0.0.0/0` regardless of tunnel health. The runtime-only vhub route (`10.0.0.0/24 via <LAN gateway>`, main table and table 101) is also lost on any reboot.

### Findings (probe output in `docs/*_results.txt`)

- Docker data-root is `/infroot/docker`, so container definitions and restart policies persist.
- A test container with `--restart unless-stopped` survived `infhostd restart-container` and a VM reboot with nothing in `/etc` or `/root`.
- `infhostd` has no user-script hook.
- The cloud-init `runcmd` in `scripts/user-data.sh` is not applied (`runcmd` skipped: "no applicable config is provided"), so `50-imds-route` was never written. Not yet fixed.
- The vhub route is absent after a reboot.

### Change (`vwan-lab-nva/`)

- `run_command.tf` (`null_resource.sse_monitor`): files now deploy to `/infroot/sse_monitor/` (script, three `frrcmds-*.json`, new `monitor.env`). The monitor is started by a launcher container `sse_monitor` (`--restart unless-stopped --privileged --pid=host --net=host`, image `infiot_image:latest`) that runs `nsenter -t 1 -m -u -i -n -- /bin/bash /infroot/sse_monitor/sse_monitor.sh`, i.e. the script runs on the host. The legacy systemd unit, logrotate file and `/root/sse_monitor/` are removed on deploy. New triggers: `lan_ip`, `lan_gateway`, `vhub_prefix`, `launcher`.
- `scripts/sse_monitor.sh`: paths moved to `/infroot/sse_monitor/`; re-asserts the vhub route (main + table 101) every loop and after each container start; rotates its own log at 100 MB.
- `scripts/sse_monitor.service` and `scripts/sse_monitor.logrotate` are no longer deployed.

### Validation (`docs/post_upgrade_results.txt`)

After a console upgrade to R6.3.406, with no Terraform intervention: `sse_monitor` and `upgrade_canary` containers up; one monitor process; vhub route present in the main table and table 101; both vhub peers Established; only `0.0.0.0/0` advertised; `/root/sse_monitor` and the systemd unit absent.

### Open items

- The launcher stays bound to the pre-upgrade image (`12912a9eb8c3`, 1.45 GB, now untagged) until the monitor is re-deployed.
- `user-data.sh` `runcmd` not applied (see Findings).

### Fail-closed default route (same day, follow-up)

Previously `frrcmds-user.json` permitted `0.0.0.0/0` unconditionally and the deny rule existed only while the monitor ran, so a missing monitor meant the default route was advertised regardless of tunnel health.

- `run_command.tf` (`null_resource.bgp_config`): `route-map set-med-peer deny 5` + `match ip address prefix-list default` added to `frrcmds-user.json`; new `frr_policy` trigger, so the next apply re-runs the BGP config (2–3 min BGP flap).
- `scripts/sse_monitor.sh`: reconciles its remembered state with the deny rule's presence in FRR `show running-config` each loop, with a self-test after each container start.
- Consequence with `gateway_count = 1`: if the monitor is not running, spokes receive no default route from the gateway.
- Tested on `vm-ntsk-gw-1`: with the monitor stopped and the container restarted, FRR loaded the deny rule and no `0.0.0.0/0` was advertised; after `docker start sse_monitor` the monitor saw 3 tunnels up and the route was re-advertised (18:19:44 UTC).

## 2026-11-12 — vWAN Lab: Documentation, Outbound BGP Filter Fix, and Routing Findings

### Documentation

Project scope narrowed to the Azure Virtual WAN deployment (`vwan-lab/` + `vwan-lab-nva/`). Documentation restructured to match the AWS project layout: a short root `README.md` plus `docs/` (Quick Start, Deployment Guide, Architecture, Operations, Troubleshooting, RBAC Permissions, State Management, DevOps Notes), and this changelog. Verification output from the 2026-11-12 deployment is summarised in [`README.md`](README.md#whats-new) and [`docs/OPERATIONS.md`](docs/OPERATIONS.md#checking-bgp-health).

### Problem

In the `vwan-lab-nva/` deployment, the gateway advertised the spoke VNet prefixes it had learned from the vhub back to the vhub, in addition to `0.0.0.0/0`:

```
   Network          Next Hop    Metric  LocPrf  Weight  Path
*> 0.0.0.0/0        0.0.0.0        10          32768   ?
*> 10.0.0.0/24      0.0.0.0        10              0   65515 i
*> 10.1.0.0/24      0.0.0.0        10              0   65515 i
*> 10.2.0.0/24      0.0.0.0        10              0   65515 i
```

This is not a routing loop (AS-path loop prevention would block it) but it is incorrect BGP policy: the gateway should advertise only the default route.

### Root Cause

The `set-med-peer` route-map applied outbound to the vhub neighbors had no `match` clause, so it permitted every route:

```
route-map set-med-peer permit 10
  set metric __BGP_METRIC__
```

The `advertise` route-map, which correctly filters to `0.0.0.0/0` via `prefix-list default`, was never applied to the vhub neighbors.

### Fix

Added a match on the default prefix-list to the `set-med-peer` clause in `vwan-lab-nva/run_command.tf`:

```
route-map set-med-peer permit 10
  match ip address prefix-list default
  set metric __BGP_METRIC__
```

Re-applied with:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Tested

| Check | Result |
|---|---|
| Advertised routes to both vhub peers | Only `0.0.0.0/0`, MED 10 |
| BGP sessions to both vhub router IPs | Established |
| Netskope overlay peers | Established, 6 prefixes received (IPsec tunnels up) |
| vhub BGP connection (`bgp-conn-ntsk-gw-1`) | `Succeeded`, peer `10.3.0.20`, ASN 400 |

### Findings (no code change required)

- **`0.0.0.0/0` does not appear in spoke effective routes.** Azure Virtual WAN does not program a BGP-learned default route into spoke VNet routes without Routing Intent. This is documented behaviour ([About BGP peering with a virtual hub](https://learn.microsoft.com/en-us/azure/virtual-wan/scenario-bgp-peering-hub)), not a deployment fault. Routing Intent requires a hub-hosted managed NVA, and Netskope BWAN is not on the supported partner list for that pattern.
- **`static_vnet_route` on `conn-nva-spoke` does not inject into the hub route table.** The `0.0.0.0/0 → GE2 IP` static route is a local routing override for that connection; it did not appear in the hub's `defaultRouteTable` or propagate to other connections. It was left in the configuration because it is harmless.

