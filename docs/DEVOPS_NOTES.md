# DevOps Notes

This document describes how the Terraform code is structured. It is intended for readers who need to change the code, not only run it. This is the most technical document in `docs/`. If you are deploying or operating the project and not editing it, you do not need this document; start with the [Deployment Guide](DEPLOYMENT_GUIDE.md) or [Operations](OPERATIONS.md).

File and resource names refer to `vwan-lab-nva/` (Phase 2) unless stated otherwise.

## Orientation

If you are new to Terraform, the following three concepts are needed to follow the rest of this page:

- **A `local` is a computed value.** `locals.tf` takes the few inputs set in `terraform.tfvars` (the number of gateways and the address range) and calculates all values derived from them: subnet CIDRs, names, and the gateway IP of each subnet. Resources then read from those locals instead of repeating the calculation.
- **`for_each` makes N copies of a resource from a map.** Almost every resource here uses `for_each = local.nvas` (or a map derived from it). This is how one block of code produces one VM, one subnet or one BGP connection per gateway. The map's keys (`ntsk-gw-1`, `ntsk-gw-2`) become part of each resource's address, e.g. `azurerm_linux_virtual_machine.nva["ntsk-gw-1"]`.
- **A `null_resource` with a `local-exec` provisioner is a script that Terraform runs.** It is not an Azure resource. The project uses it to apply configuration to the gateway after the VM boots. It re-runs only when something in its `triggers` list changes.

The rest of this document describes how these three concepts are applied in this project.

## Terraform Patterns

### Dynamic Gateway Map (`locals.tf`)

The core design pattern is a computed `local.nvas` map that generates all per-gateway configuration from `gateway_count`. It is the single source of truth consumed by every resource file, so adding a gateway requires only incrementing `gateway_count`.

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

Phase 2 takes the hub ID and router IPs as plain variables rather than reading Phase 1 state. This keeps the workspaces independent (Phase 1 can be a long-lived lab while Phase 2 is destroyed and rebuilt) at the cost of a manual copy step. A `terraform_remote_state` alternative is outlined in [State Management](STATE_MANAGEMENT.md#optional-read-phase-1-outputs-automatically).

### Phase 1 Spoke Map (`vwan-lab/locals.tf`)

Phase 1 uses the same pattern with a manually written `local.spokes` map (`spoke1`, `spoke2`) holding all per-spoke names and CIDRs. VNets, subnets, hub connections, NSGs, NICs, public IPs and VMs all `for_each` over it; a third test spoke would be a new entry in the map.

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

- `ip prefix-list default` permitting `0.0.0.0/0`
- `route-map advertise permit 10` matching that prefix-list. The gateway's built-in FRR configuration uses `route-map advertise` to filter `redistribute kernel`, `redistribute connected` and `redistribute static` (built-in entries `permit 1` and `permit 2`). This added entry is what allows the default route to be redistributed into BGP, so it must stay (`docs/verification/08_frr_minimum_test.txt`, FRR 6.0.3)
- **`route-map set-med-peer permit 10` with `match ip address prefix-list default` and `set metric <bgp_metric>`** — the `match` is what restricts outbound advertisement to the default route (see [CHANGELOG](../CHANGELOG.md)); then `route-map set-med-peer deny 5` matching the same prefix-list, which withholds the default route until the SSE monitor removes it (fail-closed)
- `router bgp <gateway_bgp_asn>` with two hub neighbours: `remote-as 65515`, `disable-connected-check`, `ebgp-multihop 255`, `route-map set-med-peer out`

The file is additive: its commands run on top of the gateway's built-in FRR configuration (FRR 6.0.3) and do not replace it. Earlier versions also added `To-Ctrlr-1..4 deny 5` entries to keep the default route away from the Netskope controller peers. These were removed on 2026-11-25, so the gateway now also advertises `0.0.0.0/0` to the two `169.254.0.x` controller peers (`docs/verification/08_frr_minimum_test.txt`).

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

`null_resource.bgp_config` re-runs only when its `triggers` change: VM name, LAN IP and gateway, both hub router IPs, ASN, metric, hub prefix, activation token, tenant URI, and the `frr_policy` version string (bump it after changing the FRR configuration). Force with `-replace`.

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

**Fail-closed:** the same `deny 5` rule is also written into `frrcmds-user.json` by `null_resource.bgp_config`, so FRR loads it at every container start and the default route is withheld unless the monitor is running and has seen a tunnel up. If the monitor is missing, `0.0.0.0/0` is not advertised. Each loop the monitor reads `show running-config` and reconciles its remembered state with whether the deny rule is actually present (logged as `DRIFT`); if it cannot recognise the output it logs a `WARNING` and falls back to remembered state. The block file is still applied once after each container start, which covers gateways whose `frrcmds-user.json` predates this change. (This differs from the AWS project, which toggles `default-originate` per neighbour.)

> **Note**: Comments in `sse_monitor.sh` refer to "TGW peers" — carried over from the AWS project; they apply to the hub router peers here.

### Deployment (`null_resource.sse_monitor`)

`run_command.tf` builds a base64-encoded tar archive locally and sends it in one Run Command script:

1. **Local build** — temp directory mirroring the target filesystem: `/infroot/sse_monitor/sse_monitor.sh`, the three `frrcmds-*.json` files (generated inline) and `monitor.env` (`VHUB_PREFIX`, `LAN_GW`, `LAN_IP`)
2. **Tar + base64** — `tar czf - infroot | base64`
3. **Substitute payload** — `python3` replaces `__PAYLOAD__` (too large for `sed`), so `python3` is needed locally
4. **Remove legacy deployment** — on the VM: disable/stop the old `sse_monitor` systemd unit, delete the unit, the logrotate file and `/root/sse_monitor/`
5. **Extract** — `base64 -d | tar xz --no-overwrite-dir -C /`, `chown -R root:root`, `chmod`
6. **Start the launcher container** — `docker rm -f sse_monitor`, then `docker run` (below); verify it is running

`--no-overwrite-dir` stops tar from resetting permissions on existing directories. The earlier deployment extracted files under `/root`, where this mattered for `sshd`; the current payload contains only `/infroot/sse_monitor/`.

`null_resource.sse_monitor` depends on `null_resource.bgp_config`. Its triggers are VM name, ASN, both peers, LAN IP, LAN gateway, vhub prefix, `filesha256("scripts/sse_monitor.sh")` and a `launcher` version string — bump `launcher` after changing the `docker run` command.

### Launcher Container and Log Rotation

A BWAN upgrade replaces the root filesystem (`/dev/sda2`), wiping `/root` and `/etc`; only `/infroot` (`/dev/sda4`) survives, and `infhostd` has no user-script hook. Docker's data-root is `/infroot/docker`, so a container definition and its restart policy do survive. The monitor is therefore started by a launcher container instead of a systemd unit:

```sh
docker run -d --name sse_monitor --restart unless-stopped \
  --privileged --pid=host --net=host \
  --entrypoint /bin/sh infiot_image:latest \
  -c 'exec nsenter -t 1 -m -u -i -n -- /bin/bash /infroot/sse_monitor/sse_monitor.sh'
```

- `nsenter -t 1` enters the host's namespaces, so the script runs on the host with the host's `bash`, `docker` and `ip`. The gateway image is used only because it is always present and contains `nsenter`.
- No `-p`: with `--pid=host` it is redundant, and with it `nsenter` forks, so `docker stop` would leave an orphaned monitor.
- The container stays bound to the image ID it was created from. After an upgrade that image is untagged (`<none>`) but kept on disk (~1.45 GB) until the launcher is re-created; re-deploying the monitor rebinds it to the current `infiot_image:latest`.

The script re-asserts the vhub route (main table and table 101) every 10 s loop and after each container start, and rotates `/var/log/sse_monitor.log` to `.1` at 100 MB itself — there is no logrotate file.

Validated 2026-11-24 through `infhostd restart-container`, a VM reboot and a console upgrade from the 6.3.371 image to R6.3.406 (`docs/post_upgrade_results.txt`). Validated again on 2026-11-25 with the fail-closed configuration on two upgraded gateways (`docs/verification/`): launcher and monitor running, hub route present, only `0.0.0.0/0` advertised to the hub, no warnings in the monitor log. On both gateways the pre-upgrade image (1.53 GB) was still on disk, held by the launcher.

## User-Data and Cloud-Init

`scripts/user-data.sh` is a cloud-config document rendered with `templatefile()` into `custom_data` in `vm.tf`. It is intended to set the gateway console password, provide the tenant URL and activation token, and pin the IMDS route. On the tested image the password and the `runcmd` steps are not applied (see Gateway Boot Process, Phase 2). No agent install is needed — the Azure VM Agent is pre-installed.

`custom_data` contains the gateway password and activation token; `lifecycle { ignore_changes = [custom_data] }` prevents a later token change from recreating the VM.

### IMDS Route Fix

After activation the `infiot_spoke` container creates an overlay interface in `169.254.0.0/16`, whose connected route would capture `169.254.169.254` (Azure IMDS). Two fixes are defined. Only the portal route is effective at present, because the cloud-init `runcmd` does not run (see the known issue under Gateway Boot Process, Phase 2):

- **Cloud-init** — `ip route add 169.254.169.254/32 dev <primary-NIC>` plus a `networkd-dispatcher` hook for persistence. The primary NIC is found as link index 2 (`awk '/^2:/'`).
- **Netskope portal** (`portal.tf`) — `netskopebwan_gateway_staticroute.metadata`: `169.254.169.254/32` via `GE1`, `install = true`, `advertise = true`.

The `/32` route always takes precedence by longest-prefix match.

## Gateway Boot Process

This section documents the full startup sequence from VM creation to a healthy, steering-active gateway. Times are approximate and from `systemd-analyze blame` on a live deployment.

### Phase 1 — Linux kernel + systemd (T+0 to ~T+10s)

| Time | Event |
|---|---|
| T+0 | Kernel boots, GRUB selects the active slot |
| T+3s | Block device (`dev-sda2.device`) attached |
| T+8s | `containerd.service` starts |
| T+10s | `systemd-networkd-wait-online` unblocks (both NICs up) |
| T+13s | `docker.service` active |

### Phase 2 — Cloud-init (T+15s to ~T+50s)

cloud-init runs in four stages against the `DataSourceAzure [seed=IMDS]` datasource. Provisioning media is not present (the image boots from an Azure Marketplace disk, not a provisioning ISO), so cloud-init falls back to IMDS user-data only — this means **admin passwords set via cloud-config are silently ignored**. The activation token and tenant URI are carried in user-data and do apply.

| Stage | Service | Duration | What it does |
|---|---|---|---|
| local | `cloud-init-local.service` | ~15s | Reads datasource, discovers network config |
| network | `cloud-init.service` | ~6s | Applies network, makes IMDS available |
| config | `cloud-config.service` | ~2s | Sets password (not effective via IMDS path); writes activation token and tenant URI consumed by infhostd |
| final | `cloud-final.service` | ~3s | Runs `runcmd` (see below) |

**`runcmd` actions (from `scripts/user-data.sh`):**

1. Pins the IMDS address to the primary NIC: `ip route add 169.254.169.254/32 dev eth0` — prevents the `169.254.0.0/16` overlay interface added later by infhostd from capturing metadata traffic.
2. Writes `/etc/networkd-dispatcher/routable.d/50-imds-route` to re-apply the route on reboots (via the networkd-dispatcher hook).

> **Known issue (2026-11-24, re-checked 2026-11-25):** these `runcmd` actions do not run. `cloud-init.log` shows `runcmd` skipped "because no applicable config is provided" and `/etc/networkd-dispatcher/routable.d/` is empty. `cloud-init query userdata` returns an empty first line on both gateways, so cloud-init appears to receive no user-data at all; the `custom_data` set in `vm.tf` is not reaching it. A possible fix, not yet tested, is to pass the same content through the VM's `user_data` argument. IMDS still resolves via the WAN interface. Evidence: `docs/boot_probe_results.txt`, `docs/canary_probe_results.txt`, `docs/verification/02_vm-ntsk-gw-1.txt`.

> On the current deployment the IMDS route already exists as an Azure fabric-injected route (`proto 196`, `metric 20`) over `10.3.0.1`. The cloud-init route (`metric 0`) would take precedence if `runcmd` ran.

### Phase 3 — infhost.service starts (~T+60s)

`infhost.service` (`/lib/systemd/system/infhost.service`):

```ini
[Unit]
Description=Infiot Host Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/infhostd
Restart=on-failure
```

On start, `infhostd` reads `/infroot/infhostd.yaml`, which defines the gateway's identity and runtime layout:

| Field | Value | Notes |
|---|---|---|
| `inf_serial` | `0000-0010-…` | Gateway serial number |
| `inf_uuid` | UUID | Unique gateway identity |
| `hwmodel` | `iXEdge_AZ` | Azure NVA hardware model |
| `interface_mappings` | `GE1=eth0`, `GE2=eth1` | Logical to physical NIC mapping |
| `infiot_containers[0].image_tar` | `/infroot/infiot.tar` | Container image on the upgrade-safe partition |
| `workdir` | `/infroot/workdir/` | Shared state dir between infhostd and container |
| `activationconfig` | `/infroot/workdir/activation_config.json` | Portal-downloaded activation state |
| `activeconfig` | `/infroot/workdir/inf_config.json` | Portal-downloaded runtime config |

infhostd also:
- Disables VLAN HW offload features on eth0/eth1 (`tx-vlan-hw-insert`, `rx-vlan-hw-parse`) — logged repeatedly to `journalctl -u infhost`
- Starts a companion process: `infhost_stats.service` (`/usr/bin/infhostd stats-collector`)

Two infhostd processes will be running: the main daemon (`/bin/infhostd`) and the stats collector (`/usr/bin/infhostd stats-collector`).

### Phase 4 — Container start (~T+4 min)

infhostd starts the `infiot_spoke` Docker container from the image stored at `/infroot/infiot.tar` (loaded into the Docker store in `/infroot/docker/`). The container runs with host networking (`--hostnet`) so it can configure NICs and routes on the host network namespace directly.

```
Created: 2026-11-24T10:07:01Z   (VM kernel started ~10:03:07)
  → ~4 minutes from VM start to container running
```

Key processes inside `infiot_spoke`:

| Process | Role |
|---|---|
| FRR (`zebra`, `bgpd`) | BGP routing daemon |
| `iked` | Custom Netskope IKEv2/IPsec daemon (not strongSwan) |
| `gencfg` | FRR config applier (reads `frrcmds-*.json`, called by SSE monitor) |
| Overlay proxy | SSE tproxy for spoke traffic steering |
| Click | Data-plane forwarding |

The container mounts `/infroot/workdir/` as its working directory. This is where FRR reads `frrcmds-user.json` (the BGP configuration for this project) and where `gencfg` sockets live.

### Phase 5 — Tunnel and BGP establishment (~T+4–8 min)

After container start:

1. FRR daemon reads `frrcmds-user.json` from workdir and applies the BGP configuration (neighbor statements, route-maps).
2. `iked` initiates IKEv2 to Netskope PoPs; `ESTABLISHED` SAs appear in `ikectl show sa`.
3. FRR establishes eBGP sessions with the vhub router (`10.0.0.69`, `10.0.0.70`, AS 65515).
4. The static host route `10.0.0.0/24 via 10.3.0.17 dev eth1` (written by the Terraform Run Command) is required for BGP traffic to reach the vhub router IPs via the LAN interface.

> BGP configuration (`frrcmds-user.json`) lives in `/infroot/workdir/` and **survives firmware upgrades**. The static route to the vhub prefix does not survive a reboot or upgrade; the SSE monitor re-adds it, after which the BGP sessions re-establish without Terraform intervention.

### Phase 6 — Terraform Run Commands (one-time, post-VM-ready)

These run from `null_resource` provisioners in `run_command.tf` and are not part of the normal boot sequence — they execute once at deploy time (or on `-replace`).

**`null_resource.bgp_config`** (runs first):

1. `infhostd activate -uri $TENANT_URI -token $TOKEN` — registers the gateway with the portal; tolerates failure if already activated; waits 30s.
2. Writes `/infroot/workdir/frrcmds-user.json` with the BGP/FRR configuration (neighbor statements, route-maps, MED).
3. Adds static route: `ip route replace $VHUB_PREFIX via $LAN_GW dev eth1` (main table + table 101).
4. `service infhost restart` + `infhostd restart-container`; waits 15s; re-adds routes.
5. Polls until `infiot_spoke` is running (12 × 10s), waits 30s for FRR, verifies BGP neighbor `$BGP_PEER1` appears in `show bgp summary`.

**`null_resource.sse_monitor`** (runs after bgp_config):

1. Removes any legacy systemd-based monitor (`/root/sse_monitor/`, unit, logrotate file).
2. Deploys `/infroot/sse_monitor/sse_monitor.sh`, three `frrcmds-*.json` files and `monitor.env`.
3. Re-creates the `sse_monitor` launcher container (`--restart unless-stopped`) and verifies it is running.

### Phase 7 — Steady State

After both Run Commands complete, the gateway is fully operational:

| Process | Location | Role |
|---|---|---|
| `infhostd` (main) | Host | Config refresh, interface monitoring, container lifecycle |
| `infhostd stats-collector` | Host | Stats aggregation |
| `infiot_spoke` container | Host network ns | FRR (BGP), iked (IPsec), overlay proxy, data plane |
| `sse_monitor.sh` (started by the `sse_monitor` launcher container) | Host | Tunnel health monitor; controls BGP 0.0.0.0/0 advertisement; maintains the vhub route |
| `walinuxagent.service` | Host | Azure VM Agent; required for Run Command to function |

### File Locations and Upgrade Survival

This mapping is the most important for operations. It determines what survives a BWAN firmware upgrade:

| File/Dir | Location | Survives upgrade? | Notes |
|---|---|---|---|
| Gateway identity & config | `/infroot/infhostd.yaml` | Yes | Serial, UUID, interface mappings |
| FRR/BGP config | `/infroot/workdir/frrcmds-user.json` | Yes | Written by Terraform Run Command |
| Activation state | `/infroot/workdir/activation_config.json` | Yes | Downloaded from portal on first boot |
| Container image | `/infroot/infiot.tar` / `/infroot/docker/` | Yes | New image written here during upgrade |
| Runtime state (sockets, caches) | `/infroot/workdir/` | Yes | All runtime infhostd/container state |
| Factory recovery image | `/infroot/backups/factory-swupdate.swu` | Yes | Baseline fallback |
| SSE monitor script, FRR JSON, `monitor.env` | `/infroot/sse_monitor/` | Yes | Verified through upgrade to R6.3.406 |
| SSE monitor launcher container | `sse_monitor` (definition in `/infroot/docker/`) | Yes | Restarted by Docker on boot; stays bound to the pre-upgrade image |
| vhub static route | Kernel routing table (main + table 101) | **No** | Runtime-only; re-added by the SSE monitor |
| SSE monitor log | `/var/log/sse_monitor.log` | **No** | On the root filesystem; starts fresh after upgrade |
| Anything under `/root` or `/etc` | Root filesystem (`/dev/sda2`) | **No** | Replaced on upgrade — do not deploy there |

**After an upgrade:** IPsec, BGP, the vhub route and the SSE monitor all recover without Terraform. See [Operations — After a Gateway Upgrade](OPERATIONS.md#after-a-gateway-upgrade) for the checks and optional clean-up.

## Hub Connection Static Route

`nva_spoke.tf` no longer sets a `static_vnet_route` on `conn-nva-spoke`. The hub learns `0.0.0.0/0` from each gateway over BGP and passes it to the spokes through `internet_security_enabled = true` on the spoke connections (`vwan-lab/spokes.tf`). A static route accepts only one next hop, so the BGP-learned route is used to get ECMP across gateways.

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

## Runtime Diagnostics

The gateway runs a single container: **`infiot_spoke`**. All Netskope data-plane processes run inside it. The IKE daemon is a custom binary called **`iked`** (not strongswan or charon).

### BGP Status

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

Healthy output shows two peers with AS 65515 (vhub router IPs `10.0.0.69`, `10.0.0.70`) in `Established` state with prefixes received, plus two iBGP peers (`169.254.0.x/400`).

### IPsec Tunnel Status

The IKE daemon is `iked` (custom Netskope binary). No `ipsec` or `strongswan` command is available.

**Live tunnel state** (authoritative — what the SSE monitor queries):

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke ikectl show sa"
```

The SSE monitor counts lines with `ESTABLISHED` matching `@infiot.com`. A non-zero count means tunnels are up and the default route will be advertised. This is the only reliable tunnel health signal — see the false indicator note below.

**IKE log** (most detailed — includes IKE_INIT / IKE_AUTH exchange and failure reasons):

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke tail -100 /var/log/iked.log"
```

`AUTHENTICATION_FAILED` entries in `iked.log` during `IKE_AUTH` mean the gateway's PSK/identity was rejected by a specific PoP. This is a portal-side issue — verify the gateway policy has PoP assignments configured. However, **these failures do not mean all tunnels are down**: a gateway may successfully establish SAs to some PoPs while failing others simultaneously. Always use `ikectl show sa` tunnel count, not `iked.log` failures, to judge overall tunnel health.

**Tunnel interfaces** (overlay interface is UP even when IPsec auth fails — it carries control-plane traffic only):

```sh
docker exec infiot_spoke ip link show   # look for 'overlay' interface
```

### SSE Steering Verification

**Do not use `pvtWanInetAccess`** in `infiot-overlay.json` as a health indicator. In testing, this flag remained `false` even while SSE was actively steering spoke traffic through Netskope PoPs. It is set by the cloud controller independently of actual forwarding behaviour and is not a reliable signal.

The authoritative end-to-end check is to run a curl from a spoke VM and inspect the egress IP:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-spoke1-test01 \
  --command-id RunShellScript \
  --scripts "curl -s --max-time 30 http://ifconfig.me"
```

If SSE steering is active the returned IP will be a Netskope PoP address (e.g. `163.116.x.x`). If traffic is bypassing SSE it will be the GE1 public IP of the NVA gateway or the vhub's NAT IP.

**BGP default route advertisement** (precondition for steering — confirm before testing from spoke):

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show ip bgp neighbors 10.0.0.69 advertised-routes'"
```

Healthy output shows `0.0.0.0/0` with next-hop `0.0.0.0` and weight `32768`.

### Other Useful Logs (inside `infiot_spoke`)

| Log file | Contents |
|---|---|
| `/var/log/iked.log` | IKEv2 exchange details, SA lifecycle |
| `/var/log/click.log` | Data-plane / overlay forwarding |
| `/var/log/infovlproxy.log` | Overlay proxy (SSE tproxy) |
| `/var/log/gencfg.log` | FRR config apply output |
| `/var/log/frrstdout.log` | FRR daemon stdout |
| `/var/log/supervisord.log` | All processes startup/restart |

### SSE Monitor Status

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw \
  --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker ps --filter name=sse_monitor; pgrep -fa sse_monitor.sh; tail -50 /var/log/sse_monitor.log"
```

## Pre-Commit and Validation

Input validation blocks:

- `gateway_count`: 1–4 (Phase 2)

Recommended pre-commit hooks:

- `terraform fmt` — formatting
- `terraform validate` — syntax and type checking
- `tflint` — linting
- `tfsec` or `checkov` — security scanning
