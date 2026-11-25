# Troubleshooting

Start with the section that matches your symptom:

- **`terraform apply` failed** → [Deployment Errors](#deployment-errors)
- **Apply succeeded but BGP is not up, or the hub is not receiving the default route** → [Diagnostic Flowchart](#diagnostic-flowchart-default-route-not-reaching-the-hub)
- **Behaviour appears incorrect but may be expected** → [Known Limitations](#known-limitations)
- **You need to run a command on the gateway** → [Running Commands on the Gateway](#running-commands-on-the-gateway) and the [command reference](#gateway-commands-quick-reference)

## Running Commands on the Gateway

Most checks below are marked "*on the gateway*". SSH is not required for these checks. Azure Run Command executes a command on the VM and returns the output to your terminal:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

Replace the quoted part with any command in this guide. Each call takes 20–30 seconds. `terraform output bgp_verify_commands` prints the common commands in a form that can be pasted directly. If a shell is preferred, use `ssh netskope@<ge1-public-ip>` with the `TF_VAR_admin_password` you set (`terraform output nva_ge1_public_ips` shows the address).

Note on names: the gateway's networking software runs inside a container called `infiot_spoke`, and its BGP daemon (FRR) is controlled with a tool called `vtysh`. For this reason, BGP commands have the form `docker exec infiot_spoke vtysh -c "..."`.

## Diagnostic Flowchart: Default Route Not Reaching the Hub

Follow the steps in order. Each step assumes that the previous step passed. The checks start on the Azure side, continue on the gateway, and end with Netskope.

### Step 1: Does the BGP connection exist in Azure?

```sh
az network vhub bgpconnection list --resource-group rg-ntsk-gw --vhub-name <vhub-name> -o table
```

**Pass**: one row per gateway, `ProvisioningState` = `Succeeded`, `PeerIp` = the gateway's LAN IP (compare with `terraform output nva_ge2_private_ips`), `PeerAsn` = `400`.

**Fail — no row or `Failed`**: The hub-side peer was not created or did not provision. This usually means the BGP connection was created before the hub connection was fully ready. The code includes a 60-second wait to prevent this, but Azure occasionally takes longer. Recreate it:

```sh
terraform apply -replace='azurerm_virtual_hub_bgp_connection.nva["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 2: Are the BGP sessions up on the gateway?

*On the gateway*:

```sh
docker exec infiot_spoke vtysh -c "show bgp summary"
```

**Pass**: the two hub router IPs (`10.0.0.69`, `10.0.0.70` in the lab) show a time in `Up/Down` and a number in `State/PfxRcd`.

**Fail — they show `Active`, `Connect` or `Idle`**: the gateway and hub cannot establish a session. The possible causes, in order of likelihood:

1. **The gateway is trying to reach the hub via the wrong interface.** Go to Step 3.
2. **The peer IPs in the gateway's config don't match the hub.** The gateway's BGP config was written from `virtual_router_ips` in your `terraform.tfvars`. Compare with `cd ../vwan-lab && terraform output virtual_router_ips`. If the hub has been rebuilt, the IPs have changed. Update tfvars and apply; Terraform re-runs the BGP script automatically.
3. **The BGP config file was not written.** *On the gateway*: run `cat /infroot/workdir/frrcmds-user.json`. The output should contain two `neighbor <ip> remote-as 65515` lines. If the file is missing or wrong, re-run the script:
   ```sh
   terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
   ```

**Fail — the hub rows are missing entirely**: the cause is the same as item 3 above.

### Step 3: Is the hub reachable via the LAN interface?

This check is needed because the hub's router IPs are in the hub's own range (`10.0.0.0/24`), which is *not* the gateway's LAN subnet. Without a specific route, the gateway would send BGP traffic by its default route, which uses the WAN interface toward the internet, and the traffic would never reach the hub. The deployment script adds a route for the hub range via the LAN interface to prevent this.

*On the gateway*:

```sh
ip route get 10.0.0.69            # which interface would we use to reach the hub?
ip route show table 101 | grep 10.0.0.0
```

**Pass**: the first command shows `dev eth1` (or the interface that holds the LAN IP), not the WAN interface, and the second shows a `10.0.0.0/24` route.

**Fail — route missing or via the WAN interface**: the route is runtime-only and is cleared by a reboot, an upgrade or a container restart. The SSE monitor re-adds it on each 10-second check, so a missing route normally means the monitor is not running (see Step 5). Either re-deploy the monitor, re-run the BGP script (it re-adds the route after its own restart):

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

or add the route manually for an immediate fix (`<lan-gw>` is the first usable IP of the LAN subnet, `10.3.0.17` in the lab):

```sh
ip route replace 10.0.0.0/24 via <lan-gw> dev eth1
ip route replace 10.0.0.0/24 via <lan-gw> dev eth1 table 101
```

### Step 4: Is the gateway advertising the default route?

*On the gateway*:

```sh
docker exec infiot_spoke vtysh -c "show ip bgp neighbors 10.0.0.69 advertised-routes"
```

**Pass**: exactly one line:

```
   Network          Next Hop    Metric  LocPrf  Weight  Path
*> 0.0.0.0/0        0.0.0.0        10          32768   ?
Total number of prefixes 1
```

**Fail — nothing advertised**: the SSE monitor has withdrawn the route because it sees no IPsec tunnels to Netskope (or the gateway has just restarted and the monitor has not completed its first check). Go to Step 5.

**Fail — spoke ranges (`10.1.0.0/24`, `10.2.0.0/24`) are listed too**: the gateway is re-advertising routes it learned from the hub back to the hub. The outbound filter is missing. This was a defect, fixed on 2026-11-12 (see [CHANGELOG](../CHANGELOG.md)). The current `run_command.tf` is correct, so re-running the BGP script corrects a gateway configured with the old version:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 5: Are the IPsec tunnels to Netskope up?

The SSE monitor allows BGP to advertise the default route only while at least one IPsec tunnel to Netskope is up. If there is no default route and all other checks pass, the cause is almost always that no tunnels are up.

*On the gateway*:

```sh
docker exec infiot_spoke ikectl show sa 2>/dev/null | grep ESTABLISHED | grep "@infiot.com" | wc -l
```

**Pass**: 1 or more. The `169.254.0.x` overlay peers should also show as established in `show bgp summary`.

**Fail — 0**: the monitor is working as designed; the problem is between the gateway and Netskope. Check in the SD-WAN portal whether the gateway shows as activated and online. Common causes: the gateway never activated (wrong tenant URL or token at deploy time), or UDP 4500 is blocked between the gateway's public IP and Netskope. You can re-run activation as part of the BGP script (Step 2, item 3).

**Check that the monitor itself is running**:

```sh
docker ps --filter name=sse_monitor       # launcher container Up?
pgrep -fa sse_monitor.sh                  # exactly one monitor process
tail -50 /var/log/sse_monitor.log         # "Tunnel Count=N" every 10s
ls -la /infroot/sse_monitor/              # script, three .json files, monitor.env
```

If the monitor is not running or files are missing, re-deploy it:

```sh
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 6: How does the hub use the route?

```sh
az network vhub get-effective-routes \
  --resource-group rg-ntsk-gw --name <vhub-name> \
  --resource-type HubVirtualNetworkConnection \
  --resource-id <conn-spoke1-id> -o table
```

**Expected**: the other spoke's range and the gateway spoke's range, each via its hub connection, and one `0.0.0.0/0` entry per gateway with next hop type `HubBgpConnection` and AS path `400`, while the gateways advertise the default route. On the spoke VM itself, `az network nic show-effective-route-table -g rg-ntsk-gw -n nic-vm-spoke1-test01 -o table` should show `0.0.0.0/0` with next hop type `VirtualNetworkGateway`. If `0.0.0.0/0` is missing although Steps 1–5 passed, check that the spoke connection has `internet_security_enabled = true` (see [Known Limitations](#known-limitations), item 1).

## Deployment Errors

Errors from `terraform plan` or `terraform apply`, listed approximately in the order they are likely to occur.

### `data.netskopebwan_policy.existing` — policy not found

`gateway_policy` in `terraform.tfvars` does not exactly match a policy on your Netskope tenant. Create the policy in the SD-WAN portal (or correct the spelling) and re-run.

### `Error: failed to authenticate` (netskopebwan provider)

The token is wrong or expired, or the tenant URL is wrong. Terraform derives the API address by inserting `.api` into the hostname (`example.infiot.net` → `example.api.infiot.net`). Test the token directly:

```sh
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TF_VAR_netskope_tenant_token" \
  "https://<tenant>.api.infiot.net/api/v1/policy"
```

`200` means the token works; `401` means it does not.

### `az: command not found` / `Please run 'az login'` during apply

These errors come from the scripts Terraform runs *locally* in Phase 2 (`null_resource.bgp_config` and `null_resource.sse_monitor`). The scripts use the Azure CLI directly, separately from Terraform's own Azure login. Install the CLI, run `az login`, confirm that `jq` is installed, and re-run `terraform apply`. Terraform continues from the point of failure.

### `MarketplacePurchaseEligibilityFailed` or "terms not accepted"

The Netskope image is a Marketplace image and its terms must be accepted once per subscription. Either run the command below and re-apply, or set `accept_plan = true` in `terraform.tfvars`:

```sh
az vm image terms accept \
  --publisher netskopebwan \
  --offer netskope-unified-sase-virtual-gateway \
  --plan netskope-unified-sase-virtual-gateway-r6_3_x
```

### `VMMarketplaceInvalidInput`

The selected VM size is "Generation 2 only" and the Netskope image is Generation 1. Use `Standard_DS11_v2` or another size that supports Gen1 (`az vm list-skus --location <region> --size <size> -o table` shows `HyperVGenerations` as `V1,V2` for compatible sizes).

### `SkuNotAvailable` or a zone restriction

Your subscription cannot deploy that VM size in that region or zone right now:

```sh
az vm list-skus --location <region> --size Standard_DS11 --zone true -o table
```

Any entry listed under `NotAvailableForSubscription` cannot be used. Choose another size or region.

### Hub connection rejected — address overlap

`nva_spoke_address_space` overlaps the hub range or one of the Phase 1 spokes. Virtual WAN requires every connected range to be distinct. Change it and re-apply.

### Password complexity error on the VM

`TF_VAR_admin_password` must be 12–123 characters with at least three of: uppercase, lowercase, digit, symbol. Also check that single quotes were used if it contains `!`. In zsh, `"abc!def"` is silently altered.

### Phase 1 hub deployment does not complete

Hub creation takes 15–30 minutes, and the output shows `Still creating...` for the whole period. This is expected. If Terraform times out, check the hub's provisioning state in the Azure portal, wait until it shows `Succeeded`, and run `terraform apply` again.

### `mktemp: illegal option` or `sed: invalid command code` (local scripts)

The Phase 2 scripts are written for macOS (`mktemp` templates ending in `XXXXXX`; `sed -i ''`). On Linux, GNU `sed` rejects `-i ''`. The project is tested on macOS. To run it from Linux, those `sed` lines in `run_command.tf` must be adapted.

### `terraform destroy` fails with a dependency error

Destroy Phase 2 before Phase 1. If the hub connection or BGP connection cannot be deleted, a resource was added to the hub outside Terraform. Remove it in the portal and run `destroy` again.

## Gateway Commands Quick Reference

Run these on the gateway via Run Command or SSH.

### Network

```sh
ip -br a                                    # interfaces and their IPs
ip route                                    # main routing table
ip route show table 101                     # Netskope's policy routing table
ip route get 10.0.0.69                      # which interface reaches the hub?
ping <dest-ip> -I <interface-ip>            # ping from a specific interface
```

### Gateway Management

```sh
infhostd version                                          # gateway software version
infhostd activate -uri https://<tenant> -token <token>    # (re)activate against your tenant
infhostd restart-container                                # restart the gateway software (drops BGP ~1 min; clears host routes — see Step 3)
reboot                                                    # full reboot, 2–5 min
```

### BGP and Tunnels (from the host)

```sh
docker exec infiot_spoke vtysh -c "show bgp summary"
docker exec infiot_spoke vtysh -c "show ip bgp"
docker exec infiot_spoke vtysh -c "show ip bgp neighbors <peer-ip> advertised-routes"
docker exec infiot_spoke vtysh -c "show route-map set-med-peer"       # the outbound filter; a "deny 5" clause means the SSE monitor has withdrawn the default
docker exec infiot_spoke ikectl show sa 2>/dev/null | grep ESTABLISHED | grep "@infiot.com" | wc -l   # IPsec tunnels up
```

### Inside the Container

```sh
docker exec -it infiot_spoke bash
/opt/infiot/bin/infcli.py --overlays        # overlay paths and IPsec tunnels
/opt/infiot/bin/infcli.py --show_int        # interfaces as the gateway sees them
/opt/infiot/bin/infcli.py --rt              # gateway routing table
```

### Flow Inspection

```sh
infhostd click-dump --help                  # live flows; pipe to grep
```

## Known Limitations

These items may appear to be faults, but are either by design or outside the control of this project.

1. **The default route reaches a spoke only if its hub connection has `internet_security_enabled = true`.** Phase 1 sets this on both spoke connections. If it is set to `false`, the hub still learns `0.0.0.0/0` from the gateway but does not pass it to that spoke, and the spoke keeps its direct Azure internet route. Routing Intent is not required.
2. **The hub's ASN is 65515 and cannot be changed.** Your gateway ASN (`gateway_bgp_asn`) must be a different value; the hub only accepts 16-bit ASNs.
3. **Gateway count is capped at 4** in `variables.tf`; Microsoft documents 8 BGP peers per hub.
4. **One Netskope policy for all gateways.** Per-gateway policies are not supported by this code.
5. **Run Command output is limited to about 4 KB.** Long outputs are truncated; run narrower commands.
6. **Phase 1 values are copied into Phase 2 manually.** There is no automatic link; after rebuilding the hub, update `vwan-lab-nva/terraform.tfvars` (see [Operations](OPERATIONS.md#rebuilding-the-hub-phase-1)).
7. **The `netskopebwan` provider is pinned to version 0.0.2.** Newer versions may change behaviour; test before upgrading.
8. **Azure IMDS (`169.254.169.254`) requires a specific route.** After activation the Netskope overlay uses `169.254.0.0/16`, which would otherwise capture traffic for Azure's metadata address. The Netskope portal configuration adds a `/32` static route for it through GE1. The cloud-init step intended to add the same route does not currently run (see [DevOps Notes](DEVOPS_NOTES.md#imds-route-fix)). A future gateway software change to overlay addressing could require revisiting this.
