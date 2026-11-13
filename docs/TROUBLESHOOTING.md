# Troubleshooting

Start with the section that matches your symptom:

- **`terraform apply` failed** → [Deployment Errors](#deployment-errors)
- **Apply succeeded but BGP isn't up, or the hub isn't getting the default route** → [Diagnostic Flowchart](#diagnostic-flowchart-default-route-not-reaching-the-hub)
- **Something looks wrong but may be expected** → [Known Limitations](#known-limitations) — check here first for the "no default route in spoke effective routes" case, which is not a fault
- **You need to run a command on the gateway** → [Running Commands on the Gateway](#running-commands-on-the-gateway) and the [command reference](#gateway-commands-quick-reference)

## Running Commands on the Gateway

Most checks below say "*on the gateway*". You don't need SSH for that — Azure Run Command executes a command on the VM and returns the output to your terminal:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

Swap the quoted part for any command in this guide. It takes 20–30 seconds per call, and `terraform output bgp_verify_commands` prints the common ones ready to paste. If you'd rather have a shell: `ssh netskope@<ge1-public-ip>` using the `TF_VAR_admin_password` you set (`terraform output nva_ge1_public_ips` for the address).

A note on names: the gateway's networking software runs inside a container called `infiot_spoke`, and its BGP daemon (FRR) is controlled with a tool called `vtysh`. That's why BGP commands look like `docker exec infiot_spoke vtysh -c "..."`.

## Diagnostic Flowchart: Default Route Not Reaching the Hub

Work through the steps in order; each one assumes the previous passed. The checks move from the Azure side inward to the gateway, and then out to Netskope.

### Step 1: Does Azure think the BGP connection exists?

```sh
az network vhub bgpconnection list --resource-group rg-ntsk-gw --vhub-name <vhub-name> -o table
```

**Pass**: one row per gateway, `ProvisioningState` = `Succeeded`, `PeerIp` = the gateway's LAN IP (compare with `terraform output nva_ge2_private_ips`), `PeerAsn` = `400`.

**Fail — no row or `Failed`**: The hub-side peer wasn't created or didn't provision. This usually means the BGP connection was created before the hub connection was fully ready (there's a 60-second wait in the code to prevent this, but Azure is occasionally slower). Recreate it:

```sh
terraform apply -replace='azurerm_virtual_hub_bgp_connection.nva["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 2: Are the BGP sessions up on the gateway?

*On the gateway*:

```sh
docker exec infiot_spoke vtysh -c "show bgp summary"
```

**Pass**: the two hub router IPs (`10.0.0.69`, `10.0.0.70` in the lab) show a time in `Up/Down` and a number in `State/PfxRcd`.

**Fail — they show `Active`, `Connect` or `Idle`**: the gateway and hub can't complete a session. In order of likelihood:

1. **The gateway is trying to reach the hub via the wrong interface.** Go to Step 3.
2. **The peer IPs in the gateway's config don't match the hub.** The gateway's BGP config was written from `virtual_router_ips` in your `terraform.tfvars`. Compare with `cd ../vwan-lab && terraform output virtual_router_ips`. If the hub has been rebuilt, they changed — update tfvars and apply; Terraform re-runs the BGP script for you.
3. **The BGP config file never landed.** *On the gateway*: `cat /infroot/workdir/frrcmds-user.json` — you should see two `neighbor <ip> remote-as 65515` lines. If the file is missing or wrong, re-run the script:
   ```sh
   terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
   ```

**Fail — the hub rows are missing entirely**: same as 3 above.

### Step 3: Is the hub reachable via the LAN interface?

Why this matters: the hub's router IPs live in the hub's own range (`10.0.0.0/24`), which is *not* the gateway's LAN subnet. Without a specific route, the gateway would send BGP traffic out of its default route — the WAN interface, toward the internet — and the hub would never see it. The deployment script adds a route for the hub range via the LAN interface to prevent this.

*On the gateway*:

```sh
ip route get 10.0.0.69            # which interface would we use to reach the hub?
ip route show table 101 | grep 10.0.0.0
```

**Pass**: the first command shows `dev eth1` (or whichever interface holds the LAN IP) — not the WAN interface — and the second shows a `10.0.0.0/24` route.

**Fail — route missing or via the WAN interface**: this happens if someone restarted the `infiot_spoke` container by hand, which clears host routes. Either re-run the BGP script (it re-adds the route after its own restart):

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

or add it by hand for an immediate fix (`<lan-gw>` is the first usable IP of the LAN subnet, `10.3.0.17` in the lab):

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

**Fail — nothing advertised**: the SSE monitor has withdrawn the route because it sees no IPsec tunnels to Netskope (or the gateway has just restarted and the monitor hasn't finished its first check). Go to Step 5.

**Fail — spoke ranges (`10.1.0.0/24`, `10.2.0.0/24`) are listed too**: the gateway is echoing routes it learned from the hub back to it. The outbound filter is missing. This was a real bug, fixed on 2026-11-12 (see [CHANGELOG](../CHANGELOG.md)); the current `run_command.tf` is correct, so re-running the BGP script fixes a gateway configured with the old version:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 5: Are the IPsec tunnels to Netskope up?

The SSE monitor only lets BGP advertise the default route while at least one IPsec tunnel to Netskope is up. So "no default route" with everything else healthy almost always means "no tunnels".

*On the gateway*:

```sh
docker exec infiot_spoke ikectl show sa 2>/dev/null | grep ESTABLISHED | grep "@infiot.com" | wc -l
```

**Pass**: 1 or more. You should also see the `169.254.0.x` overlay peers as established in `show bgp summary`.

**Fail — 0**: the monitor is doing its job; the problem is between the gateway and Netskope. Check in the SD-WAN portal whether the gateway shows as activated and online. Common causes: the gateway never activated (wrong tenant URL or token at deploy time), or UDP 4500 is blocked between the gateway's public IP and Netskope. You can re-run activation as part of the BGP script (Step 2, item 3).

**Check the monitor itself is alive**:

```sh
systemctl status sse_monitor              # active (running)?
tail -50 /var/log/sse_monitor.log         # "Tunnel Count=N" every 10s
ls -la /root/sse_monitor/                 # script + three .json files
```

If the service isn't running or files are missing, re-deploy it:

```sh
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

### Step 6: What does the hub actually do with the route?

```sh
az network vhub get-effective-routes \
  --resource-group rg-ntsk-gw --name <vhub-name> \
  --resource-type HubVirtualNetworkConnection \
  --resource-id <conn-spoke1-id> -o table
```

**Expected**: the other spoke's range and the gateway spoke's range, each via its hub connection. **`0.0.0.0/0` will not be listed**, even though Steps 1–5 all passed. This is not a fault — see [Known Limitations](#known-limitations), item 1.

## Deployment Errors

Errors from `terraform plan` or `terraform apply`, roughly in the order you might meet them.

### `data.netskopebwan_policy.existing` — policy not found

`gateway_policy` in `terraform.tfvars` doesn't exactly match a policy on your Netskope tenant. Create the policy in the SD-WAN portal (or fix the spelling) and re-run.

### `Error: failed to authenticate` (netskopebwan provider)

The token is wrong or expired, or the tenant URL is wrong. Terraform derives the API address by inserting `.api` into the hostname (`example.infiot.net` → `example.api.infiot.net`). Test the token directly:

```sh
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TF_VAR_netskope_tenant_token" \
  "https://<tenant>.api.infiot.net/api/v1/policy"
```

`200` means the token works; `401` means it doesn't.

### `az: command not found` / `Please run 'az login'` during apply

These come from the scripts Terraform runs *locally* in Phase 2 (`null_resource.bgp_config` and `null_resource.sse_monitor`). They use the Azure CLI directly, separately from Terraform's own Azure login. Install the CLI, run `az login`, make sure `jq` is installed, and re-run `terraform apply` — Terraform will continue from where it failed.

### `MarketplacePurchaseEligibilityFailed` or "terms not accepted"

The Netskope image is a Marketplace image and its terms must be accepted once per subscription. Either run the command below and re-apply, or set `accept_plan = true` in `terraform.tfvars`:

```sh
az vm image terms accept \
  --publisher netskopebwan \
  --offer netskope-unified-sase-virtual-gateway \
  --plan netskope-unified-sase-virtual-gateway-r6_2_x
```

### `VMMarketplaceInvalidInput`

The VM size you chose is "Generation 2 only" and the Netskope image is Generation 1. Use `Standard_DS11_v2` or another size that supports Gen1 (`az vm list-skus --location <region> --size <size> -o table` shows `HyperVGenerations` as `V1,V2` for compatible sizes).

### `SkuNotAvailable` or a zone restriction

Your subscription can't deploy that VM size in that region or zone right now:

```sh
az vm list-skus --location <region> --size Standard_DS11 --zone true -o table
```

Anything under `NotAvailableForSubscription` is off-limits. Pick another size or region.

### Hub connection rejected — address overlap

`nva_spoke_address_space` overlaps the hub range or one of the Phase 1 spokes. Virtual WAN requires every connected range to be distinct. Change it and re-apply.

### Password complexity error on the VM

`TF_VAR_admin_password` must be 12–123 characters with at least three of: uppercase, lowercase, digit, symbol. Also check you used single quotes if it contains `!` — in zsh, `"abc!def"` is silently altered.

### Phase 1 hub seems stuck

Hub creation takes 15–30 minutes and the output sits on `Still creating...` the whole time. That's normal. If Terraform does time out, check the hub's provisioning state in the Azure portal, wait for it to say `Succeeded`, and run `terraform apply` again.

### `mktemp: illegal option` or `sed: invalid command code` (local scripts)

The Phase 2 scripts are written for macOS (`mktemp` templates ending in `XXXXXX`; `sed -i ''`). On Linux, GNU `sed` rejects `-i ''`. The project is tested on macOS; running from Linux needs those `sed` lines in `run_command.tf` adapted.

### `terraform destroy` fails with a dependency error

Destroy Phase 2 before Phase 1. If the hub connection or BGP connection won't delete, something was added to the hub outside Terraform — remove it in the portal and run `destroy` again.

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

Things that look like problems but are either by design or outside this project's control.

1. **`0.0.0.0/0` never appears in spoke effective routes.** Azure Virtual WAN learns the default route from the gateway but will not push a BGP-learned default route into spoke networks unless *Routing Intent* is configured — and Routing Intent only works with Microsoft-partner appliances deployed inside the hub, which Netskope's gateway is not. Microsoft documents this in [About BGP peering with a virtual hub](https://learn.microsoft.com/en-us/azure/virtual-wan/scenario-bgp-peering-hub). The BGP peering and advertisement are still correct and verifiable (Steps 1–5).
2. **The static `0.0.0.0/0` route on the gateway's hub connection does nothing hub-wide.** `nva_spoke.tf` sets one; testing showed it only affects traffic *to* the gateway spoke and does not enter the hub's shared route table. It's harmless and left in place. It also only accepts one next hop, so with two gateways it points at the first.
3. **The hub's ASN is 65515 and can't be changed.** Your gateway ASN (`gateway_bgp_asn`) must be something else; the hub only accepts 16-bit ASNs.
4. **Gateway count is capped at 4** in `variables.tf`; Microsoft documents 8 BGP peers per hub.
5. **One Netskope policy for all gateways.** Per-gateway policies aren't supported by this code.
6. **Run Command output is cut off at about 4 KB.** Long outputs are truncated; run narrower commands.
7. **Gateways are configured one at a time** during apply, so multi-gateway deployments take proportionally longer.
8. **Restarting the container by hand clears the hub route.** `infhostd restart-container` or a reboot removes the route added in Step 3. Re-run `null_resource.bgp_config` (or add the route by hand) afterwards.
9. **SSH can break after an old-style SSE monitor deploy.** Extracting the monitor's files to `/` without `--no-overwrite-dir` loosens `/root`'s permissions from `700` to `755`, and `sshd` then refuses logins. The current code has the flag. If a gateway is affected, fix it via Run Command — `--scripts "chmod 700 /root"` — then re-deploy the monitor.
10. **Phase 1 values are copied into Phase 2 by hand.** There's no automatic link; after rebuilding the hub, update `vwan-lab-nva/terraform.tfvars` (see [Operations](OPERATIONS.md#if-you-rebuild-the-hub-phase-1)).
11. **The `netskopebwan` provider is pinned to version 0.0.2.** Newer versions may change behaviour; test before upgrading.
12. **Azure IMDS (`169.254.169.254`) needs a pinned route.** After activation the Netskope overlay claims `169.254.0.0/16`, which would swallow Azure's metadata address. Both cloud-init and the portal config add a `/32` route for it to the WAN interface. A future gateway software change to overlay addressing could require revisiting this.
