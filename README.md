# Netskope SD-WAN Gateway — Azure Virtual WAN Terraform Project

Deploys and activates Netskope SD-WAN (BWAN) gateways as NVA VMs in an Azure Virtual WAN spoke, with eBGP peering to the virtual hub's built-in router. This project handles the full lifecycle: Virtual WAN and hub, spoke VNets, Netskope portal configuration, VM provisioning, and post-launch FRR/BGP and SSE monitor setup via Azure Run Command.

## When to Use This Project

This project implements Netskope Borderless SD-WAN with BGP in an Azure Virtual WAN topology — the **spoke-based NVA + vhub BGP** pattern. Use it to test or demonstrate dynamic route exchange between a Netskope gateway and a Virtual WAN hub, with the gateway advertising and withdrawing a default route based on IPsec tunnel health.

### How It Works

BWAN gateways run as Azure VMs in a dedicated spoke VNet connected to the virtual hub. Each gateway registers its GE2 (LAN) IP as a BGP peer on the hub (`azurerm_virtual_hub_bgp_connection`) and peers back to both hub router IPs from GE2. GE1 (WAN) carries the IPsec/UDP 4500 overlay to Netskope NewEdge Data Planes.

The gateway advertises `0.0.0.0/0` to the hub with MED 10. An SSE monitor on each gateway checks IPsec tunnel state every 10 seconds: with tunnels up the default route is advertised; with tunnels down it is withdrawn, so a gateway without a path to Netskope never attracts traffic.

### Routing Intent Limitation

Azure Virtual WAN learns `0.0.0.0/0` from the NVA and holds it in the hub's BGP RIB, but **does not program it into spoke VNet effective routes without Routing Intent**. Routing Intent requires a hub-hosted managed NVA, which Netskope BWAN does not support. This is intentional, documented Azure behaviour ([About BGP peering with a virtual hub](https://learn.microsoft.com/en-us/azure/virtual-wan/scenario-bgp-peering-hub)), not a deployment fault. The BGP session and route advertisement are still verified and correct. See [Architecture — Routing Behaviour](docs/ARCHITECTURE.md#routing-behaviour) for the two patterns.

### Key Benefits

- **No agents required** — works with any OS or container runtime that receives routes from the hub
- **Dynamic routing** — the gateway and hub exchange routes over BGP; no manual UDRs for spoke or branch prefixes
- **Tunnel-aware advertisement** — the SSE monitor withdraws the default route when no IPsec tunnel to Netskope NewEdge is established, preventing a blackhole
- **Scales by count** — `gateway_count` drives subnets, NICs, VMs, portal objects and hub BGP connections (1–4 gateways)

## What's New

### 2026-11-12 — Verified deployment and BGP outbound filter fix

Deployed to westeurope with one `Standard_DS11_v2` gateway in Zone 3. Both hub BGP sessions and both Netskope overlay sessions established; the gateway advertised exactly `0.0.0.0/0` (MED 10) to both hub router IPs.

The `set-med-peer` outbound route-map had no `match` clause and re-advertised spoke VNet prefixes learned from the hub back to it. Fixed by adding `match ip address prefix-list default` in `vwan-lab-nva/run_command.tf`. See the [CHANGELOG](CHANGELOG.md).

---

## What This Project Does

Two Terraform workspaces, applied in order:

**Phase 1 — `vwan-lab/`**
- Creates a resource group, a Standard Virtual WAN and one virtual hub
- Creates two spoke VNets, each with a subnet, NSG, and an Ubuntu 22.04 test VM with a public IP
- Connects both spokes to the hub; outputs the hub ID, router IPs and ASN for Phase 2

**Phase 2 — `vwan-lab-nva/`**
- Creates an NVA spoke VNet with a GE1 (WAN) and GE2 (LAN) subnet per gateway, NSGs, NICs and public IPs
- Connects the spoke to the hub and creates one hub BGP connection per gateway
- Registers gateways in the Netskope SD-WAN portal (policy, interfaces, IMDS static route, BGP peers, activation)
- Deploys 1–4 gateway VMs from the Netskope Marketplace image with cloud-init activation
- Pushes FRR/BGP and networking configuration to each gateway via Azure Run Command
- Deploys the SSE monitor (systemd service) that controls default route advertisement

## Architecture

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

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the resource inventory, subnet layout, BGP design and security layers.

## Quick Start

```sh
git clone <repository-url>
cd terraform-netskopebwan-azure-vhub
az login

# Phase 1 — Virtual WAN, hub, spokes (hub takes 15–30 min)
cd vwan-lab
cp example.tfvars terraform.tfvars        # set ssh_public_key_path, ssh_source_address
terraform init && terraform apply -var-file=terraform.tfvars
terraform output virtual_hub_id virtual_router_ips virtual_router_asn

# Phase 2 — Netskope gateways
cd ../vwan-lab-nva
cp example.tfvars terraform.tfvars        # paste Phase 1 outputs, set gateway_policy
export TF_VAR_netskope_tenant_url="your-tenant.infiot.net"
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
export TF_VAR_admin_password='YourOsPassword123!'   # single quotes: zsh ! expansion
terraform init && terraform apply -var-file=terraform.tfvars
```

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for a step-by-step walkthrough with expected outputs.

## Prerequisites

- **Terraform** >= 1.3 with providers: `azurerm ~> 3.0`, `netskopebwan 0.0.2`, `null ~> 3.0`, `time ~> 0.7`
- **Azure CLI** (`az`) installed and authenticated (`az login`) — also used by the Run Command provisioners
- **`jq`** — required by `scripts/azure_run_command.sh`
- **Azure subscription** with Contributor at subscription or resource group scope (see [docs/RBAC_PERMISSIONS.md](docs/RBAC_PERMISSIONS.md))
- **Netskope SD-WAN tenant** with tenant URL and a REST API token
- **Netskope gateway policy** created in the SD-WAN portal before deploying (Phase 2 references it by name)
- **Marketplace terms accepted** for the Netskope BWAN image — set `accept_plan = true`, or run:
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_2_x
  ```

## VM Image

| Field | Value |
|---|---|
| Publisher | `netskopebwan` |
| Offer | `netskope-unified-sase-virtual-gateway` |
| SKU / Plan | `netskope-unified-sase-virtual-gateway-r6_2_x` |
| Version | `6.2.5` |
| Generation | Gen1 |

**Important**: Gen1 only. Gen2-only sizes (e.g. `Standard_D2s_v6`) fail with `VMMarketplaceInvalidInput`. Tested size: `Standard_DS11_v2`. Check zone availability before deploying:

```sh
az vm list-skus --location <region> --size Standard_DS11 --zone true -o table
```

## Outputs

### Phase 1 (`vwan-lab/`)

| Output | Description |
|---|---|
| `virtual_hub_id` | Hub resource ID — **Phase 2 input** |
| `virtual_router_ips` | Hub BGP router IPs (two, for HA) — **Phase 2 input** |
| `virtual_router_asn` | Hub router ASN (always 65515) — **Phase 2 input** |
| `virtual_hub_name`, `virtual_wan_id`, `resource_group_name`, `location` | Lab context |
| `spoke_vnet_ids`, `spoke_vnet_address_spaces`, `spoke_subnet_ids`, `hub_connection_ids` | Per-spoke details |
| `vm_private_ips`, `vm_public_ips` | Test VM addresses |

### Phase 2 (`vwan-lab-nva/`)

| Output | Description |
|---|---|
| `nva_vm_names` | Gateway key → VM name |
| `nva_ge1_public_ips` | Interface key → GE1 (WAN) public IP |
| `nva_ge2_private_ips` | Interface key → GE2 (LAN) private IP (BGP peer IP registered on the hub) |
| `nva_spoke_vnet_id`, `hub_connection_id` | NVA spoke VNet and hub connection IDs |
| `vhub_bgp_connection_ids` | Gateway key → hub BGP connection resource ID |
| `bgp_verify_commands` | Ready-to-run `az` commands to verify BGP state |

## Documentation

Start with the **Quick Start** to get deployed, then refer to the **Deployment Guide** for the full configuration reference.

| Document | Description |
|---|---|
| [Quick Start](docs/QUICKSTART.md) | Get deployed fast — Phase 1, Phase 2, credentials, verify |
| [Deployment Guide](docs/DEPLOYMENT_GUIDE.md) | Full variable reference for both workspaces, authentication, scaling, destruction |
| [Architecture](docs/ARCHITECTURE.md) | Topology, subnet layout, resource inventory, BGP design, routing behaviour, security layers |
| [Operations](docs/OPERATIONS.md) | Day-2: re-running BGP config, SSE monitor re-deploy, gateway access, BGP verification, hub redeploy |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Diagnostic steps, common errors, gateway command reference, known limitations |
| [RBAC Permissions](docs/RBAC_PERMISSIONS.md) | Azure roles for the Terraform operator and CI/CD |
| [State Management](docs/STATE_MANAGEMENT.md) | Remote backend setup (Azure Blob Storage) |
| [DevOps Notes](docs/DEVOPS_NOTES.md) | Internal patterns, provider details, Run Command and SSE monitor design, variable flow |
| [Changelog](CHANGELOG.md) | Dated fixes and findings |

## Support

Netskope-provided scripts in this and other GitHub projects do not fall under the regular Netskope technical support scope and are not supported by Netskope support services.
