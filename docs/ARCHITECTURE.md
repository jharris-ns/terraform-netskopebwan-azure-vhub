# Architecture

What this project builds, how the pieces connect, and why it's shaped the way it is. The first half is for anyone who needs to understand the deployment; the second half (inventory, file map, BGP detail) is reference material.

## The Big Picture

Azure **Virtual WAN** is Microsoft's managed hub-and-spoke network. You create a **virtual hub** in a region, and any VNet you connect to it (a **spoke**) can automatically reach every other spoke through the hub — no peering, no route tables to maintain. The hub contains a BGP-speaking router that Microsoft runs for you.

This project puts a **Netskope SD-WAN gateway** in its own spoke and lets it talk BGP to that hub router. Through that conversation the gateway learns the hub's and spokes' address ranges, and tells the hub "I can reach everything — send me the default route". The gateway's other side is an IPsec tunnel to Netskope's cloud (NewEdge), so traffic that reaches the gateway is inspected by Netskope on its way to the internet.

One safety mechanism matters above all: the gateway only offers the default route while its tunnels to Netskope are actually up. A small service on the gateway (the **SSE monitor**) checks every 10 seconds and withdraws the route if the tunnels drop, so a gateway that has lost Netskope never pulls in traffic it can't forward.

```
                       Azure Virtual WAN
              ┌─────────────────────────────────────┐
              │  vhub  (10.0.0.0/24, ASN 65515)      │
              │  router IPs: 10.0.0.69, 10.0.0.70    │
              └──┬──────────┬──────────┬─────────────┘
       conn-spoke1│          │conn-spoke2│conn-nva-spoke
                  │          │          │
     ┌────────────▼─┐ ┌──────▼───────┐ ┌▼──────────────────────┐
     │ Spoke 1       │ │ Spoke 2      │ │ NVA Spoke              │
     │ 10.1.0.0/24   │ │ 10.2.0.0/24  │ │ 10.3.0.0/24            │
     │ test VM       │ │ test VM      │ │                        │
     └───────────────┘ └──────────────┘ │ vm-ntsk-gw-n           │
                                        │ GE1 (WAN) — public IP  │
                                        │ GE2 (LAN) — eBGP ──────┼──► vhub router IPs
                                        │ BGP ASN: 400           │
                                        └────────────┬───────────┘
                                                     │ IPsec / UDP 4500
                                                     ▼
                                            Netskope NewEdge
                                            (overlay peers:
                                             169.254.0.x)
```

### The two phases

The build is split into two Terraform folders so the slow, stable part and the fast, frequently-rebuilt part are independent:

- **Phase 1 — `vwan-lab/`**: the Virtual WAN, the hub, and two small spoke VNets each with an Ubuntu test VM. The test VMs exist so you can prove spoke-to-spoke routing works and have somewhere to generate traffic from. Takes 15–30 minutes, almost all of it the hub.
- **Phase 2 — `vwan-lab-nva/`**: a third spoke containing the Netskope gateway(s), the BGP peering to the hub, the gateway's registration in the Netskope portal, and the two scripts that configure it after boot. Takes 10–15 minutes and can be torn down and rebuilt without touching Phase 1.

Phase 2 needs three facts from Phase 1 — the hub's ID and its two router IPs (plus the ASN, always 65515) — which you copy from Phase 1's output into Phase 2's settings file.

### The gateway's two interfaces

Each gateway VM has two network cards, and the distinction runs through everything:

| | GE1 — WAN | GE2 — LAN |
|---|---|---|
| Azure subnet | `snet-ge1-<gateway>` (public) | `snet-ge2-<gateway>` (private) |
| Public IP | Yes | No |
| Security group | `nsg-nva-public`: SSH and UDP 4500 in, all out | `nsg-nva-private`: all in, all out |
| What uses it | IPsec tunnels to Netskope; SSH management; the VM's default route | BGP to the hub router; traffic to/from the spokes |
| Netskope portal zone | untrusted, NAT on, overlay on | trusted, no overlay |

The WAN card is listed first on the VM so Azure makes it the default route. That means anything not specifically routed elsewhere goes out to the internet — including, if we did nothing, BGP packets destined for the hub router. So the configuration script adds a route on the gateway sending the hub's address range (`10.0.0.0/24`) out of the LAN card instead. If that route is missing, BGP never comes up; it's Step 3 of the [troubleshooting flowchart](TROUBLESHOOTING.md#step-3-is-the-hub-reachable-via-the-lan-interface).

## Traffic Flow

1. **BGP control plane**: gateway GE2 ↔ both hub router IPs. The gateway advertises `0.0.0.0/0` (MED 10) while tunnels are up and learns the hub and spoke ranges.
2. **Netskope overlay**: gateway GE1 (public IP) ↔ Netskope NewEdge POPs over IPsec/UDP 4500. Two overlay BGP peers (`169.254.0.x`) run over these tunnels; their state is the SSE monitor's health signal.
3. **Management**: operator → GE1 public IP (SSH), or Azure Run Command from your own machine (no open port needed).
4. **Spoke to spoke**: Spoke 1 ↔ hub ↔ Spoke 2 — built-in Virtual WAN transit, no UDRs.

## Routing Behaviour

This is the part of the design that most often surprises people, so it gets its own section.

**What happens**: the gateway advertises `0.0.0.0/0` to the hub, and the hub accepts it — you can see it in the gateway's `advertised-routes` output and the hub's BGP connection shows `Succeeded`. But if you look at a spoke's *effective routes* in Azure, there is no default route. The spokes' internet traffic still leaves directly from each spoke VNet.

**Why**: Azure Virtual WAN deliberately does not install a BGP-learned default route into spoke networks. Microsoft's reasoning is safety — a misconfigured appliance in a spoke must not be able to blackhole every spoke's internet traffic. The only way to make a hub send spoke traffic through an appliance is a feature called **Routing Intent**, and Routing Intent requires the appliance to be a Microsoft-partner "managed NVA" deployed *inside the hub*. Netskope's gateway is a spoke VM, not a hub NVA, so Routing Intent isn't available. This is documented at [About BGP peering with a virtual hub](https://learn.microsoft.com/en-us/azure/virtual-wan/scenario-bgp-peering-hub).

**What that means for this project**: it validates the *spoke-based NVA + hub BGP* pattern — the gateway and hub exchange routes dynamically, and the gateway's default-route advertisement responds correctly to tunnel health. It does not, on its own, steer spoke internet traffic through Netskope.

| Pattern | What it gives you | Requires |
|---|---|---|
| **NVA in spoke + hub BGP** (this project) | Dynamic route exchange between the gateway, hub, spokes and any branches — no manual UDRs for those prefixes | `azurerm_virtual_hub_bgp_connection` |
| **NVA in hub + Routing Intent** | Spoke internet and/or private traffic forced through the appliance | A Microsoft-partner managed NVA in the hub + `azurerm_virtual_hub_routing_intent`. Netskope BWAN is not on the partner list. |

The hub connections are created with `internet_security_enabled = false`, which is the explicit "don't send my internet traffic through the hub" setting; it's consistent with the above.

## Address Plan

### Phase 1

| Network | CIDR | Purpose |
|---|---|---|
| Virtual hub | 10.0.0.0/24 | Reserved for the hub itself; the router IPs are allocated from here |
| Spoke 1 VNet / `snet-vm` | 10.1.0.0/24 / 10.1.0.0/26 | Test VM |
| Spoke 2 VNet / `snet-vm` | 10.2.0.0/24 / 10.2.0.0/26 | Test VM |

### Phase 2

The gateway spoke is `nva_spoke_address_space` (default `10.3.0.0/24`), and Terraform carves it into `/28` subnets automatically — two per gateway, WAN then LAN:

| Subnet | CIDR | Purpose |
|---|---|---|
| `snet-ge1-ntsk-gw-1` | 10.3.0.0/28 | Gateway 1 WAN |
| `snet-ge2-ntsk-gw-1` | 10.3.0.16/28 | Gateway 1 LAN — its `.20` is the BGP peer IP; `.17` is the subnet gateway used for the hub route |
| `snet-ge1-ntsk-gw-2` | 10.3.0.32/28 | Gateway 2 WAN |
| `snet-ge2-ntsk-gw-2` | 10.3.0.48/28 | Gateway 2 LAN |

Virtual WAN refuses to connect any VNet whose range overlaps the hub or another connected VNet, so all of the above must stay distinct.

## Security Layers

**Network security groups** — Phase 2:

| NSG | Direction | Rule | Purpose |
|---|---|---|---|
| `nsg-nva-public` (GE1) | Inbound | TCP/22 from `*` | SSH management — consider restricting the source |
| `nsg-nva-public` (GE1) | Inbound | UDP/4500 from `*` | IPsec NAT-T for the Netskope tunnels |
| `nsg-nva-public` (GE1) | Outbound | All | Tunnels and updates |
| `nsg-nva-private` (GE2) | Inbound / Outbound | All | Trusted side |

Phase 1 spoke NSGs allow SSH only from `ssh_source_address` and ICMP from within the virtual network.

**Public IPs** are Standard SKU, static, zone-redundant — the address survives the VM being moved between zones.

**Azure metadata protection**: after activation, Netskope's overlay claims `169.254.0.0/16`, which would also swallow Azure's instance metadata address `169.254.169.254`. A `/32` route for that address is pinned to the WAN card both by cloud-init on first boot and as a static route in the Netskope portal, so Azure's agent keeps working.

**Secrets**: the Netskope token, OS password and gateway password are passed to Terraform as environment variables and never written to `terraform.tfvars`. They *are* present in the Terraform state file and in the VM's cloud-init data, which is why state must be protected (see [State Management](STATE_MANAGEMENT.md)).

## How the Gateway Gets Configured

Creating the VM is only half the job. Terraform then runs two scripts *on* the VM using Azure Run Command (Azure's built-in "execute this on the VM" facility — no SSH needed):

1. **`null_resource.bgp_config`** activates the gateway against your Netskope tenant, writes the BGP configuration (hub peers, outbound filter), adds the LAN route to the hub, and restarts the gateway software. It waits for BGP neighbours to appear before finishing.
2. **`null_resource.sse_monitor`** installs the SSE monitor as a systemd service, along with the three small FRR command files it uses to add or remove the default-route block.

Because these are scripts rather than Azure resources, Terraform re-runs them only when their inputs change or when you ask with `-replace` — explained in [Operations](OPERATIONS.md#the-one-terraform-concept-you-need--replace). The mechanics are in [DevOps Notes](DEVOPS_NOTES.md#azure-run-command-design).

## Reference: BGP Design

**Hub router**: ASN 65515 (fixed by Azure), two router IPs from the hub range. One `azurerm_virtual_hub_bgp_connection` per gateway registers the gateway's GE2 IP and ASN as a peer.

**Gateway (FRR inside the `infiot_spoke` container)**:

- ASN `gateway_bgp_asn` (default 400); peers with both hub IPs as `remote-as 65515`
- `ebgp-multihop 2` and `disable-connected-check` — because the hub IPs are not on the GE2 subnet
- Outbound route-map `set-med-peer`: permits only `0.0.0.0/0` (`match ip address prefix-list default`) and sets MED 10. The `match` is what stops spoke prefixes learned from the hub being echoed back — a bug fixed on 2026-11-12 (see [CHANGELOG](../CHANGELOG.md)).
- Toward Netskope's overlay controllers (`To-Ctrlr-*`): the default route is denied, and an HA community `47474:47474` is set
- **Default-route control**: the SSE monitor inserts `route-map set-med-peer deny 5` (matching the default prefix) when tunnels are down and removes it when they're up. Nothing uses `default-originate`.

**Host route**: `ip route replace <hub-prefix> via <GE2-subnet-gateway> dev <LAN-intf>`, in both the main table and policy table 101.

## Reference: Resource Inventory

### Phase 1 Azure resources

| Resource | Count | Notes |
|---|---|---|
| Resource group | 1 | Shared with Phase 2 |
| Virtual WAN | 1 | `Standard` (Basic can't do BGP peering and can't be upgraded in place) |
| Virtual hub | 1 | 15–30 min to provision |
| Spoke VNets / subnets | 2 / 2 | `snet-vm` in each |
| Hub VNet connections | 2 | `internet_security_enabled = false` |
| NSGs / associations | 2 / 2 | SSH from `ssh_source_address`, ICMP from VirtualNetwork |
| Public IPs / NICs / VMs | 2 / 2 / 2 | Ubuntu 22.04 LTS Gen2, `Standard_B2s` |

### Phase 2 Azure resources (per deployment)

| Resource | Count | Notes |
|---|---|---|
| Virtual network | 1 | The gateway spoke |
| Subnets | 2 × gateway_count | GE1 + GE2 per gateway |
| Hub VNet connection | 1 | `conn-nva-spoke`, with a `static_vnet_route` (see Known Limitations) |
| Hub BGP connections | gateway_count | One per gateway, GE2 IP as peer |
| NSGs | 2 | `nsg-nva-public`, `nsg-nva-private` |
| NSG associations | 4 × gateway_count | Subnet-level and NIC-level per interface |
| Public IPs | gateway_count | GE1 only; Standard, static, zone-redundant |
| NICs | 2 × gateway_count | GE1 (primary) + GE2 (IP forwarding on) |
| VMs | gateway_count | Netskope Marketplace image, Premium_LRS OS disk, `plan {}` block required |
| Marketplace agreement | 0–1 | Only when `accept_plan = true` |
| `time_sleep` | 2 + gateway_count | API settle (30s), hub-connection delay (60s), per-gateway portal propagation (30s) |

### Phase 2 Netskope portal resources

| Resource | Count | Notes |
|---|---|---|
| Policy | 1 | Looked up by name — must pre-exist |
| Gateway | gateway_count | Model `iXVirtual`, role `gateway_role` |
| Gateway interface | 2 × gateway_count | GE1 (untrusted, NAT, overlay) + GE2 (trusted) |
| Static route | gateway_count | IMDS `169.254.169.254/32` via GE1 |
| BGP config | 2 × gateway_count | Two hub router IPs per gateway |
| Activation | gateway_count | Token consumed by cloud-init |

## Reference: File Map

### Phase 1 — `vwan-lab/`

| File | Purpose |
|---|---|
| `vwan.tf` | Resource group, Virtual WAN, virtual hub |
| `spokes.tf` | Spoke VNets, subnets, hub connections |
| `nsg.tf` | Per-spoke NSGs |
| `vm.tf` | Public IPs, NICs, test VMs |
| `locals.tf` | `local.spokes` — names and CIDRs for both spokes |
| `outputs.tf` | Hub ID, router IPs/ASN (Phase 2 inputs), spoke and VM details |

### Phase 2 — `vwan-lab-nva/`

| File | Purpose |
|---|---|
| `locals.tf` | `local.nvas` map from `gateway_count`; subnet carving; interface and BGP-peer maps |
| `nva_spoke.tf` | Gateway spoke VNet, subnets, hub connection, 60s delay |
| `vhub_bgp.tf` | Hub BGP connection per gateway |
| `nsg.tf` | Public/private NSGs and subnet associations |
| `interfaces.tf` | GE1 public IPs, GE1/GE2 NICs, NIC-level NSG associations |
| `vm.tf` | Marketplace agreement, gateway VMs with cloud-init |
| `portal.tf` | Netskope portal: policy lookup, gateways, interfaces, IMDS route, BGP peers, activation |
| `run_command.tf` | The two post-boot scripts (`bgp_config`, `sse_monitor`) |
| `outputs.tf` | Names, IPs, connection IDs, ready-made verify commands |
| `provider.tf`, `variables.tf`, `versions.tf` | Providers, inputs, version pins |
| `scripts/user-data.sh` | Cloud-init: passwords, tenant URL, activation token, IMDS route |
| `scripts/azure_run_command.sh` | Helper that waits for the VM and runs a script on it |
| `scripts/sse_monitor.sh`, `.service`, `.logrotate` | The SSE monitor and its systemd/logrotate files |

## Provider Versions

| Provider | Source | Version | Purpose |
|---|---|---|---|
| `azurerm` | hashicorp/azurerm | ~> 3.0 | Azure infrastructure |
| `netskopebwan` | netskopeoss/netskopebwan | 0.0.2 | Netskope portal configuration (Phase 2) |
| `null` | hashicorp/null | ~> 3.0 | The post-boot scripts (Phase 2) |
| `time` | hashicorp/time | ~> 0.7 | Deliberate waits (Phase 2) |
| Terraform | — | >= 1.3 | Core |
