# CLAUDE.md — Netskope BWAN Azure vWAN Lab

This file gives Claude context about this project. Read it before making changes.

## What This Project Does

Tests that Netskope SD-WAN (BWAN) gateways, deployed as NVA VMs in an Azure Virtual WAN spoke, advertise `0.0.0.0/0` to the vWAN hub router via eBGP, and that the SSE monitor controls that advertisement based on IPsec tunnel health.

Two-phase Terraform deployment:
- **`vwan-lab/`** — Virtual WAN, one hub, two spoke VNets with test VMs (Phase 1)
- **`vwan-lab-nva/`** — Netskope NVA spoke, gateway VMs, vhub BGP connection, FRR config, SSE monitor (Phase 2)

## Documentation

Always check the relevant doc before making changes in that area.

| Doc | When to read it |
|---|---|
| [README.md](README.md) | Overview, quick start, architecture diagram, known gotchas |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Shortest path to a working deployment with expected outputs; 45 min end-to-end |
| [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) | Step-by-step with explanations — full variable reference, authentication, scaling, destruction |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Topology, subnet layout, resource inventory, BGP design, Routing Intent behaviour |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2: re-running BGP config / SSE monitor, gateway replacement, hub redeploy, BGP verification |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom-based: deployment errors, BGP not establishing, SSE monitor issues, known limitations |
| [docs/RBAC_PERMISSIONS.md](docs/RBAC_PERMISSIONS.md) | Azure roles, Marketplace terms, CI/CD runner requirements |
| [docs/STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md) | What Terraform state is, Azure Blob Storage backend setup, one state key per workspace |
| [docs/DEVOPS_NOTES.md](docs/DEVOPS_NOTES.md) | Terraform code internals — patterns, provider design, Run Command and SSE monitor implementation |
| [CHANGELOG.md](CHANGELOG.md) | Dated fixes and findings |

## File Map — `vwan-lab-nva/` (Phase 2, the active workspace)

| File | Purpose |
|---|---|
| `variables.tf` | All input variable declarations |
| `locals.tf` | NVA map auto-computed from `gateway_count`; subnet CIDR carving (`local.nvas`, `local.nva_interfaces`) |
| `nva_spoke.tf` | NVA spoke VNet, subnets, hub connection (`conn-nva-spoke`), hub BGP connections |
| `interfaces.tf` | NICs and Public IPs (GE1 WAN + GE2 LAN per gateway) |
| `vm.tf` | Azure VMs (Netskope Marketplace image, cloud-init) |
| `portal.tf` | Netskope portal resources: gateways, interfaces, IMDS static route, BGP peers, activation |
| `run_command.tf` | Azure Run Command: FRR/BGP config + SSE monitor deployment |
| `outputs.tf` | Outputs: VM names, public IPs, GE2 IPs, vhub BGP connection IDs, verify commands |
| `provider.tf` | `azurerm` and `netskopebwan` provider configuration |
| `versions.tf` | Provider version constraints |
| `example.tfvars` | Clean config template — safe to commit |
| `terraform.tfvars` | Live deployment values — **gitignored, never commit** |
| `scripts/user-data.sh` | Cloud-init: gateway password, tenant URL, activation token |
| `scripts/azure_run_command.sh` | Run Command helper: polls VM agent, invokes script synchronously |
| `scripts/sse_monitor.sh` | IPsec tunnel health monitor — controls BGP default route advertisement |

## Current Deployed State

| Resource | Value |
|---|---|
| Resource group | `rg-ntsk-gw` (westeurope) |
| Virtual hub | `vhub-ntsk-gw-westeurope-01` (10.0.0.0/24) |
| vhub router IPs | `10.0.0.69`, `10.0.0.70` (ASN 65515) |
| Spoke 1 | `10.1.0.0/24`, test VM `10.1.0.4` |
| Spoke 2 | `10.2.0.0/24`, test VM `10.2.0.4` |
| NVA spoke | `10.3.0.0/24` |
| Gateway | `vm-ntsk-gw-1`, `Standard_DS11_v2`, Zone 3, GE2 IP `10.3.0.20` |
| Gateway BGP ASN | `400` |
| Netskope policy | `absa-test` |

## Critical Gotchas

### 1. VM image is Gen1 only

The Netskope BWAN Marketplace image is Generation 1. Gen2-only VM sizes (e.g. `Standard_D2s_v6`) fail with `VMMarketplaceInvalidInput`. Use `Standard_DS11_v2` or another Gen1-compatible size.

### 2. Zone capacity — always check before deploying or changing VM size

```sh
az vm list-skus --location westeurope --size Standard_DS11 --zone true -o table
```

Zone capacity is subscription-specific. Current deployment uses Zone 3 because Zones 1 and 2 are restricted for `Standard_DS11_v2` in this subscription. Always verify before choosing a zone.

### 3. The `plan {}` block is always required in `vm.tf`

Azure requires the `plan` block for Marketplace VMs regardless of `accept_plan` value. Never make it conditional.

### 4. `az login` must be done before `terraform apply`

The `local-exec` provisioners in `run_command.tf` call `az vm run-command invoke` directly. The Azure CLI must be authenticated before applying. Also requires `jq`.

### 5. macOS `sed -i` requires an empty-string argument

`run_command.tf` uses `sed -i '' "s|...|...|g"`. Do not remove the `''` — it fails on macOS BSD `sed`.

### 6. BGP outbound filter must only permit `0.0.0.0/0`

The `route-map set-med-peer permit 10` clause in the FRR config JSON must include `match ip address prefix-list default`. Without it, spoke VNet prefixes learned from the vhub are re-advertised back. This is already correct — do not remove the `match` condition.

### 7. Phase 1 outputs are manually copied into Phase 2 `terraform.tfvars`

No remote state link between workspaces. If the hub is redeployed, re-run `terraform output` in `vwan-lab/` and update `vwan-lab-nva/terraform.tfvars`.

### 8. Secrets use single quotes in zsh

`TF_VAR_admin_password` values containing `!` must use single quotes in zsh to avoid history expansion:
```sh
export TF_VAR_admin_password='Netsk0pe!2024'
```

### 9. Terraform providers need Unix socket access

The `azurerm`, `null`, `time`, and `netskopebwan` providers communicate via Unix sockets. Run `terraform` outside any sandbox that restricts socket creation.

## Key Variables (`vwan-lab-nva/terraform.tfvars`)

```hcl
# Phase 1 outputs
virtual_hub_id      = "/subscriptions/.../virtualHubs/vhub-ntsk-gw-westeurope-01"
virtual_router_ips  = ["10.0.0.70", "10.0.0.69"]
vhub_address_prefix = "10.0.0.0/24"

location            = "westeurope"
resource_group_name = "rg-ntsk-gw"
nva_spoke_address_space = "10.3.0.0/24"

gateway_count   = 1
gateway_prefix  = "ntsk-gw"
gateway_bgp_asn = 400
gateway_policy  = "absa-test"

vm_size     = "Standard_DS11_v2"
accept_plan = false
```

## Re-running Configuration

```sh
# Force BGP config re-run (after run_command.tf changes)
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars

# Force SSE monitor re-deploy
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```
