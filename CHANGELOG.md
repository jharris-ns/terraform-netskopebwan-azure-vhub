# Changelog

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

