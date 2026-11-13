# DevOps Notes

How the Terraform code is put together, for anyone who needs to change it rather than just run it. This is the most technical document in `docs/`; if you're deploying or operating the project rather than editing it, you don't need it — start with the [Deployment Guide](DEPLOYMENT_GUIDE.md) or [Operations](OPERATIONS.md).

File and resource names refer to `vwan-lab-nva/` (Phase 2) unless stated otherwise.

## Orientation

If you're new to Terraform, three ideas make the rest of this page readable:

- **A `local` is a computed value.** `locals.tf` takes the handful of inputs you set in `terraform.tfvars` (how many gateways, what address range) and works out everything derived from them — subnet CIDRs, names, which IP is the gateway for which subnet. Resources then read from those locals instead of repeating the arithmetic.
- **`for_each` makes N copies of a resource from a map.** Almost every resource here says `for_each = local.nvas` (or a map derived from it), which is how one block of code produces one VM, or one subnet, or one BGP connection per gateway. The map's keys (`ntsk-gw-1`, `ntsk-gw-2`) become part of each resource's address, e.g. `azurerm_linux_virtual_machine.nva["ntsk-gw-1"]`.
- **A `null_resource` with a `local-exec` provisioner is a script Terraform runs for you.** It isn't an Azure resource; it's how the project pushes configuration onto the gateway after the VM boots. It re-runs only when something in its `triggers` list changes.

Everything below is detail on those three ideas as applied here.

## Terraform Patterns

### Dynamic Gateway Map (`locals.tf`)

The core design pattern is a computed `local.nvas` map that generates all per-gateway configuration from `gateway_count`. It is the single source of truth consumed by every resource file — adding a gateway requires only incrementing `gateway_count`.

```hcl
locals {
  spoke_prefix_len = tonumber(split("/", var.nva_spoke_address_space)[1])

  nvas = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {
      ge1_subnet  = cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2)
      ge2_subnet  = cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2 + 1)
      ge1_gateway = cidrhost(<ge1_subnet>, 1)   # Azure subnet gateway is always the first usable IP
      ge2_gateway = cidrhost(<ge2_subnet>, 1)
    }
  }
}
```

Map keys are stable names (`ntsk-gw-1`, `ntsk-gw-2`) rather than numeric indices, so adding a gateway does not force recreation of the others. Even `i` carves the GE1 (WAN) subnet and odd `i` the GE2 (LAN) subnet.

Example with `nva_spoke_address_space = 10.3.0.0/24`, `subnet_size = 28`, `gateway_count = 2`:

```
"ntsk-gw-1" => { ge1 = 10.3.0.0/28,  ge2 = 10.3.0.16/28, ge2_gateway = 10.3.0.17 }
"ntsk-gw-2" => { ge1 = 10.3.0.32/28, ge2 = 10.3.0.48/28, ge2_gateway = 10.3.0.49 }
```

### `for_each` Over the Gateway Map

Per-gateway resources iterate over `local.nvas`:

```hcl
resource "azurerm_linux_virtual_machine" "nva" {
  for_each = local.nvas
  name     = "vm-${each.key}"
  # ...
}
```

This yields stable resource addresses such as `azurerm_linux_virtual_machine.nva["ntsk-gw-1"]` and `null_resource.bgp_config["ntsk-gw-1"]`, which are the addresses used with `-replace` in [Operations](OPERATIONS.md).

### Flattened Interface and Peer Maps

Interface-level resources (subnets, NICs, NSG associations) need one entry per gateway × interface, so `locals.tf` flattens the gateway map:

```hcl
nva_interfaces = merge([
  for gw_key, gw in local.nvas : {
    "${gw_key}-ge1" = { gw_key = gw_key, intf = "ge1", subnet = gw.ge1_subnet, gateway = gw.ge1_gateway, public = true  }
    "${gw_key}-ge2" = { gw_key = gw_key, intf = "ge2", subnet = gw.ge2_subnet, gateway = gw.ge2_gateway, public = false }
  }
]...)

nva_public_interfaces  = { for k, v in local.nva_interfaces : k => v if v.public }
nva_private_interfaces = { for k, v in local.nva_interfaces : k => v if !v.public }
```

The trailing `...` is Terraform's expansion syntax — it unpacks the list of maps from the outer `for` into separate arguments for `merge()`.

BGP peers are flattened the same way, two per gateway:

```hcl
nva_bgp_peers = merge([
  for gw_key in keys(local.nvas) : {
    "${gw_key}-peer1" = { gw_key = gw_key, neighbor = local.vhub_peer_ips[0] }
    "${gw_key}-peer2" = { gw_key = gw_key, neighbor = local.vhub_peer_ips[1] }
  }
]...)
```

`vhub_peer_ips` is `sort(tolist(var.virtual_router_ips))` — sorting gives a stable `[0]`/`[1]` ordering, since set iteration order is not deterministic.

### Phase 1 → Phase 2 Handoff

Phase 2 takes the hub ID and router IPs as plain variables rather than reading Phase 1 state. This keeps the workspaces independent (Phase 1 can be a long-lived lab while Phase 2 is destroyed and rebuilt) at the cost of a manual copy step. A `terraform_remote_state` alternative is sketched in [State Management](STATE_MANAGEMENT.md#optional-stop-copying-phase-1-values-by-hand).

### Phase 1 Spoke Map (`vwan-lab/locals.tf`)

Phase 1 uses the same pattern with a hand-written `local.spokes` map (`spoke1`, `spoke2`) holding all per-spoke names and CIDRs. VNets, subnets, hub connections, NSGs, NICs, public IPs and VMs all `for_each` over it; a third test spoke would be a new entry in the map.

## Provider Internals

### Netskope BWAN Provider

The `netskopebwan` provider (source `netskopeoss/netskopebwan`, pinned to `0.0.2`) communicates with the Netskope SD-WAN REST API.

**Credentials** (`provider.tf`): `netskope_tenant_url` and `netskope_tenant_token` are standalone, `sensitive` variables set via `TF_VAR_*`. The scheme is stripped so `"https://${local.tenant_url}"` in `run_command.tf` never doubles it:

```hcl
tenant_url_raw = trimprefix(trimprefix(var.netskope_tenant_url, "https://"), "http://")
```

**API URL transformation**: the API hostname inserts `api` as the second label:

```hcl
tenant_url_slice     = split(".", local.tenant_url_raw)
tenant_api_url_slice = concat(slice(local.tenant_url_slice, 0, 1), ["api"], slice(local.tenant_url_slice, 1, length(local.tenant_url_slice)))
tenant_api_url       = "https://${join(".", local.tenant_api_url_slice)}"
```

| Tenant URL (input) | API URL |
|---|---|
| `https://example.infiot.net` | `https://example.api.infiot.net` |
| `example.infiot.net` | `https://example.api.infiot.net` |

### Azure Provider

`features {}` plus `subscription_id = var.subscription_id != "" ? var.subscription_id : null`, so an empty variable falls through to the `az login` default. The Run Command provisioners call the Azure CLI separately, so the CLI must also be authenticated.

### API Propagation Delays

| Resource | Duration | Purpose |
|---|---|---|
| `time_sleep.nsg_api_delay` | 30s | Let the Netskope API settle before creating gateways |
| `time_sleep.gw_propagation` (per gateway) | 30s | After `netskopebwan_gateway`; children read `triggers["gateway_id"]` so the dependency is implicit |
| `time_sleep.hub_connection_delay` | 60s | After `azurerm_virtual_hub_connection` — Azure returns success before hub routing is active; BGP connections created earlier fail |

## Azure Run Command Design

Post-launch configuration is applied with Azure Run Command from `null_resource` `local-exec` provisioners in `run_command.tf`. This replaces the AWS project's SSM document and send-command flow.

| AWS (SSM) | Azure |
|---|---|
| `aws_ssm_document` | Inline script in a `local-exec` heredoc |
| `aws ssm send-command` + polling | `az vm run-command invoke` (synchronous) |
| `scripts/ssm_send_command.sh` | `scripts/azure_run_command.sh` |
| SSM VPC endpoints, SSM agent install | Not needed — the Azure VM Agent is pre-installed |
| GRE tunnel configuration | Not needed — direct eBGP to the hub router |

### Config Push Sequence (`null_resource.bgp_config`)

One script per gateway:

1. **Activate** — `infhostd activate -uri $TENANT_URI -token $TOKEN`; a failure is tolerated (already activated), then 30s wait
2. **Write FRR config** — `/infroot/workdir/frrcmds-user.json` (see below)
3. **Networking** — detect the LAN interface by matching its private IP; `ip route replace $VHUB_PREFIX via $LAN_GW dev $LAN_INTF`; restart `infhost` service and container; wait 15s; re-add the route in the main table and table 101
4. **Verify** — wait for `infiot_spoke` (12 × 10s), wait 30s for FRR, check that the first hub peer appears in `show bgp summary`; exits 0 with a warning if not

The LAN interface name is detected at run time (`ip -o addr show | awk ...`) rather than hard-coded.

### FRR Configuration

The JSON written in step 2 contains, in order:

- Community list `HA_COMMUNITY` (`47474:47474`)
- `ip prefix-list default` permitting `0.0.0.0/0`; `route-map advertise permit 10` matching it; **`route-map set-med-peer permit 10` with `match ip address prefix-list default` and `set metric <bgp_metric>`** — the `match` is what restricts outbound advertisement to the default route (see [CHANGELOG](../CHANGELOG.md))
- `router bgp <gateway_bgp_asn>` with two hub neighbours: `remote-as 65515`, `disable-connected-check`, `ebgp-multihop 2`, `route-map set-med-peer out`
- `To-Ctrlr-1..4 deny 5` matching the default prefix-list — keeps the default route off the Netskope overlay controllers
- `From-Ctrlr-1..3 deny 6` matching `HA_COMMUNITY`; `To-Ctrlr-1..4 permit 10` setting the community additively

`default-originate` is not used. Default route advertisement is controlled by the SSE monitor through a deny clause on `set-med-peer` (below).

### Helper Script

```sh
scripts/azure_run_command.sh <resource_group> <vm_name> <script_file> <comment> [subscription]
```

1. Polls `az vm get-instance-view` until `PowerState/running` (30 × 10s)
2. Polls until the VM Agent reports `ProvisioningState/succeeded` (30 × 10s); proceeds with a warning otherwise
3. Runs `az vm run-command invoke --command-id RunShellScript --scripts "$(cat file)"` — synchronous
4. Parses stdout/stderr with `jq`; exits 1 on invocation failure

Constraints: Azure CLI and `jq` must be installed locally; output is capped at ~4 KB; the script is passed as one argument, so it is bounded by shell `ARG_MAX`; the subscription falls back to `AZURE_SUBSCRIPTION_ID` when the fifth argument is empty.

### Script Templating

The gateway script is a single-quoted heredoc containing `__PLACEHOLDER__` tokens (`__BGP_ASN__`, `__BGP_PEER1__`, `__VHUB_PREFIX__`, `__TOKEN__`, …) replaced with `sed -i ''` before invocation.

- `sed -i ''` is BSD (macOS) syntax; GNU `sed` fails on it. Do not change it without handling both platforms.
- macOS `mktemp` needs the `X`s at the end of the template; the script renames the file to add `.sh` afterwards.
- The activation token is substituted into the script text and is therefore part of the Run Command payload.

### Re-run Triggers

`null_resource.bgp_config` re-runs only when its `triggers` change: VM name, LAN IP and gateway, both hub router IPs, ASN, metric, hub prefix, activation token, tenant URI. Force with `-replace`.

## SSE Monitor

The SSE monitor is a health-checking daemon on each gateway that prevents blackholing by controlling BGP default route advertisement according to IPsec tunnel state.

### How It Works

`scripts/sse_monitor.sh` runs an infinite loop:

```
                    ┌──────────────┐
          startup → │  retracted   │  (initial state forces first advertise)
                    └──────┬───────┘
                           │ tunnels UP → apply frrcmds-advertise-default.json
                    ┌──────▼───────┐
                    │  advertised  │
                    └──────┬───────┘
                           │ tunnels DOWN → apply frrcmds-retract-default.json
                    ┌──────▼───────┐
                    │  retracted   │
                    └──────────────┘
```

1. **Container check** — reads `docker inspect` `StartedAt` for `infiot_spoke`; if down, waits 10s and retries
2. **Restart detection** — a changed `StartedAt` triggers a 30s stabilization wait, applies `frrcmds-block-default-redistribute.json`, and resets state to *retracted*
3. **Poll loop** (every 10s) — counts `ESTABLISHED` entries matching `@infiot.com` in `ikectl show sa`; 0 tunnels while advertised → retract; ≥ 1 while retracted → advertise
4. Transitions are idempotent — FRR is only reconfigured on a state change

### FRR JSON Files

The monitor copies a JSON file into the container with `docker cp` and applies it with `/opt/infiot/bin/gencfg -run-frr-cmds`. The default route is toggled by adding or removing a deny clause ahead of the permit on the outbound route-map:

**`frrcmds-block-default-redistribute.json`** and **`frrcmds-retract-default.json`** (identical content):

```json
{ "frrCmdSets": [{ "frrCmds": [
  "conf t",
  "route-map set-med-peer deny 5",
  "match ip address prefix-list default"
] }] }
```

**`frrcmds-advertise-default.json`**:

```json
{ "frrCmdSets": [{ "frrCmds": [
  "conf t",
  "no route-map set-med-peer deny 5"
] }] }
```

The block file is applied once after each container start so the default route is withheld from boot until the first tunnel check passes. (This differs from the AWS project, which toggles `default-originate` per neighbour.)

> **Note**: Comments in `sse_monitor.sh` refer to "TGW peers" — carried over from the AWS project; they apply to the hub router peers here.

### Deployment (`null_resource.sse_monitor`)

`run_command.tf` builds a base64-encoded tar archive locally and sends it in one Run Command script:

1. **Local build** — temp directory mirroring the target filesystem: `/root/sse_monitor/sse_monitor.sh`, the three `frrcmds-*.json` files (generated inline), `/etc/systemd/system/sse_monitor.service`, `/etc/logrotate.d/sse_monitor`
2. **Tar + base64** — `tar czf - root etc | base64`
3. **Substitute payload** — `python3` replaces `__PAYLOAD__` (too large for `sed`), so `python3` is needed locally
4. **Extract and start** — on the VM: `base64 -d | tar xz --no-overwrite-dir -C /`, `chmod 755`, `systemctl daemon-reload`, `enable`, `restart`

`--no-overwrite-dir` stops tar from resetting permissions on existing directories such as `/root`; without it `/root` becomes `755` and `sshd` rejects logins (see [Troubleshooting — Known Limitations](TROUBLESHOOTING.md#known-limitations)).

`null_resource.sse_monitor` depends on `null_resource.bgp_config`. Its triggers are VM name, ASN, both peers and `filesha256("scripts/sse_monitor.sh")` — editing the script re-deploys; editing `.service` or `.logrotate` does not.

### Systemd Service and Log Rotation

`sse_monitor.service`: `After=docker.service`, `Requires=docker.service`, `Restart=always`, `RestartSec=10`, `WantedBy=multi-user.target`.

`sse_monitor.logrotate`: rotates `/var/log/sse_monitor.log` at 100 MB, keeps 3 compressed archives, `copytruncate` so the running script needs no signal.

## User-Data and Cloud-Init

`scripts/user-data.sh` is a cloud-config document rendered with `templatefile()` into `custom_data` in `vm.tf`. It sets the gateway console password, provides the tenant URL and activation token (consumed by the BWAN image on first boot), and pins the IMDS route. No agent install is needed — the Azure VM Agent is pre-installed.

`custom_data` contains the gateway password and activation token; `lifecycle { ignore_changes = [custom_data] }` prevents a later token change from recreating the VM.

### IMDS Route Fix

After activation the `infiot_spoke` container creates an overlay interface in `169.254.0.0/16`, whose connected route would capture `169.254.169.254` (Azure IMDS). The fix is applied twice:

- **Cloud-init** — `ip route add 169.254.169.254/32 dev <primary-NIC>` plus a `networkd-dispatcher` hook for persistence. The primary NIC is found as link index 2 (`awk '/^2:/'`).
- **Netskope portal** (`portal.tf`) — `netskopebwan_gateway_staticroute.metadata`: `169.254.169.254/32` via `GE1`, `install = true`, `advertise = true`.

The `/32` always wins by longest-prefix match.

## Hub Connection Static Route

`nva_spoke.tf` adds a `static_vnet_route` (`0.0.0.0/0 → first gateway GE2 IP`) to `conn-nva-spoke`. Testing showed this is a local routing override for that connection only — it does not inject into the hub's `defaultRouteTable` or propagate to other spokes. It is harmless and left in place; the comment block in `nva_spoke.tf` describing hub-wide propagation predates that finding.

## Variable Flow

```
Phase 1 (vwan-lab/)                                Phase 2 (vwan-lab-nva/)
variables.tf ──► locals.tf (local.spokes)           variables.tf ──► locals.tf (local.nvas, nva_interfaces, nva_bgp_peers)
   │                                                   │
   ├──► vwan.tf     RG, Virtual WAN, hub               ├──► nva_spoke.tf   VNet, subnets, hub connection (+60s delay)
   ├──► spokes.tf   VNets, subnets, hub connections    ├──► nsg.tf         public/private NSGs + subnet associations
   ├──► nsg.tf      per-spoke NSGs                     ├──► interfaces.tf  GE1 PIPs, GE1/GE2 NICs, NIC NSG associations
   ├──► vm.tf       PIPs, NICs, test VMs               ├──► vhub_bgp.tf    hub BGP connection per gateway (GE2 IP)
   └──► outputs.tf  virtual_hub_id, virtual_router_ips ├──► portal.tf      Netskope gateways, interfaces, IMDS route,
                      │                                │                   BGP peers, activation tokens
                      │  manual copy into tfvars       ├──► vm.tf          Marketplace agreement, VMs (cloud-init)
                      └───────────────────────────────►├──► run_command.tf bgp_config → sse_monitor (Run Command)
                                                       └──► outputs.tf     names, IPs, connection IDs, verify commands
```

## Pre-Commit and Validation

Input validation blocks:

- `gateway_count`: 1–4 (Phase 2)

Recommended pre-commit hooks:

- `terraform fmt` — formatting
- `terraform validate` — syntax and type checking
- `tflint` — linting
- `tfsec` or `checkov` — security scanning
