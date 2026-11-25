# Operations

This document describes how to change, repair and check the deployment after it is running. It is written for readers who can run `terraform apply` but may not know Terraform in detail. Each procedure explains the reason for its commands.

Unless stated otherwise, run commands from `vwan-lab-nva/` with your `TF_VAR_` secrets exported (see [Deployment Guide — secrets](DEPLOYMENT_GUIDE.md#32-set-the-secrets-as-environment-variables)). If you have opened a new terminal since the deployment, export them again first.

## Using Terraform `-replace`

Most changes follow the same steps: edit `terraform.tfvars`, run `terraform plan` to review the effect, then run `terraform apply`. Terraform calculates the difference and changes only the affected resources.

Two resources behave differently. The BGP configuration and the SSE monitor are not Azure resources. They are *scripts that Terraform ran on the gateway VM once*. Terraform calls these `null_resource`s and only re-runs them if one of their inputs changes. To run one again (for example, after editing the script or after the gateway lost its configuration), instruct Terraform to treat the resource as needing recreation:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

`-replace` means "destroy and recreate this one resource". For a `null_resource`, "recreate" means only that the script runs again. Nothing in Azure is changed. The `["ntsk-gw-1"]` part identifies the gateway; use `["ntsk-gw-2"]` for the second, and so on. This pattern is used throughout this page.

## Scaling: Adding or Removing a Gateway

Change one value and apply:

```hcl
# terraform.tfvars
gateway_count = 2   # was 1
```

```sh
terraform plan  -var-file=terraform.tfvars    # should show only additions
terraform apply -var-file=terraform.tfvars
```

The new gateway receives the next pair of subnets, its own VM, public IP, Netskope portal entry and hub BGP connection, and both scripts run on it. The existing gateway is not changed. The plan should show `0 to change, 0 to destroy`. If it shows any resource being destroyed, stop and review the plan.

Reducing the count destroys the highest-numbered gateway(s), including their portal entries.

**Limit**: 1–4 gateways. Microsoft documents a maximum of 8 BGP peers per virtual hub.

## Replacing a Gateway VM

Use this procedure if the VM is unhealthy, or if a different VM size is required. Changing `vm_size` in `terraform.tfvars` and applying has the same effect: Terraform recreates the VM because the size cannot be changed in place.

```sh
# 1. Recreate the VM
terraform apply -replace='azurerm_linux_virtual_machine.nva["ntsk-gw-1"]' -var-file=terraform.tfvars

# 2. Re-run both scripts on the new VM
terraform apply \
  -replace='null_resource.bgp_config["ntsk-gw-1"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-1"]' \
  -var-file=terraform.tfvars
```

Step 2 is required because a new VM has none of the configuration that the scripts installed. Terraform does not detect this, because the inputs to the scripts have not changed. The gateway's entry in the Netskope portal (name, interfaces, BGP peers) is kept, and the new VM activates against the same entry.

## Re-Running the BGP Configuration

Re-run the BGP configuration when the FRR/BGP settings in `run_command.tf` have been edited, or when the hub's router IPs have changed. The route to the hub is maintained by the SSE monitor and does not need this script after a restart.

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

The script performs these actions on the gateway, in order: re-activates against your Netskope tenant (this has no adverse effect if the gateway is already active), writes the BGP configuration file, adds the route that sends hub traffic out of the LAN interface, restarts the gateway software, re-adds the route, then waits and prints `show bgp summary`. The script takes 2–3 minutes. The gateway's BGP sessions drop and re-establish during this time, so plan for the interruption if the gateway is carrying traffic.

If you changed `virtual_router_ips` in `terraform.tfvars`, `-replace` is not required. These values are inputs to the script, so Terraform re-runs it automatically.

## Re-Deploying the SSE Monitor

The SSE monitor is a monitoring script on the gateway. It checks the IPsec tunnels to Netskope and allows BGP to advertise the default route only while at least one tunnel is up. It also keeps the route to the hub installed. It is stored in `/infroot/sse_monitor/` and is started by a launcher container named `sse_monitor`, so it persists across reboots and gateway upgrades.

Terraform re-deploys it automatically when `scripts/sse_monitor.sh` or its inputs change. To force a re-deploy:

```sh
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

To re-run both scripts on every gateway in a single apply, list each resource:

```sh
terraform apply \
  -replace='null_resource.bgp_config["ntsk-gw-1"]' \
  -replace='null_resource.bgp_config["ntsk-gw-2"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-1"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-2"]' \
  -var-file=terraform.tfvars
```

## After a Gateway Upgrade

An upgrade from the Netskope console replaces the gateway's root filesystem. No re-deployment is required: the tunnels, BGP, the hub route and the SSE monitor recover automatically (verified on upgrades from the 6.3.371 image, most recently on two gateways on 2026-11-25). Verify on the gateway:

```sh
docker ps -a --format "{{.Names}} {{.Image}} {{.Status}}"   # infiot_spoke and sse_monitor both Up
tail -20 /var/log/sse_monitor.log                           # Tunnel Count=N every 10s
ip route show 10.0.0.0/24                                   # via the LAN gateway, dev eth1
docker exec infiot_spoke vtysh -c 'show bgp summary'        # both hub peers Established
```

Optional clean-up: the launcher remains bound to the pre-upgrade gateway image, which remains on disk untagged (about 1.5 GB). Re-deploying the monitor rebinds it to the new image; `docker image prune` then frees the space.

```sh
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

## Rebuilding the Hub (Phase 1)

Destroying and recreating the Virtual WAN hub gives it a new resource ID and new router IPs. Phase 2 holds copies of the old values in its `terraform.tfvars`, so retrieve the new values:

```sh
cd vwan-lab
terraform output virtual_hub_id virtual_router_ips virtual_router_asn
```

Copy the new values into `vwan-lab-nva/terraform.tfvars` (and update `vhub_address_prefix` there if the hub address range changed), then in `vwan-lab-nva/` run `terraform plan` and `terraform apply`. Terraform updates the hub connection and BGP connections, updates the BGP peers in the Netskope portal, and re-runs the BGP script because its inputs changed. `-replace` is not required.

## Rotating the Netskope API Token

1. Create a new REST API token in the SD-WAN portal (Accounts → REST API)
2. `export TF_VAR_netskope_tenant_token="NEW_TOKEN"`
3. Run `terraform plan`. It should report `No changes`. The token is used only to call the API; it is not stored in any resource.

## Accessing a Gateway

Direct access is not usually required. Azure Run Command executes a command on the VM from your own machine and returns the output, without SSH or open ports:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

Replace the quoted command with any command from the [gateway command reference](TROUBLESHOOTING.md#gateway-commands-quick-reference). `terraform output bgp_verify_commands` prints the most useful commands with your resource names already filled in.

If a shell is required, connect by SSH to the gateway's public IP as the OS user `netskope` with the `TF_VAR_admin_password` you set:

```sh
terraform output nva_ge1_public_ips
ssh netskope@<ge1-public-ip>
```

## Checking BGP Health

Run `show bgp summary` on the gateway (via Run Command or SSH):

```
Neighbor        V    AS  MsgRcvd  MsgSent  Up/Down     State/PfxRcd
10.0.0.69       4  65515    114     103    01:37:44     3
10.0.0.70       4  65515    122     111    01:40:26     3
169.254.0.38    4   400     116     109    01:40:33     6
169.254.0.39    4   400     111     113    01:40:31     6
```

How to read the output:

- The two `65515` rows are the hub's router IPs. A time in `Up/Down` means the session is established; the number on the right is the number of routes the hub is sending to the gateway (hub range plus the spokes).
- The two `169.254.0.x` rows are Netskope's overlay peers. If these are established, the IPsec tunnels to Netskope are up. If they show `Active`/`Connect`, the gateway cannot reach Netskope. In that case the SSE monitor will have withdrawn the default route, which is the correct response.

Next, check which routes the gateway is advertising to the hub:

```sh
docker exec infiot_spoke vtysh -c "show ip bgp neighbors 10.0.0.69 advertised-routes"
```

Expected: exactly one route, `0.0.0.0/0`, metric `10`. If spoke ranges are also listed, or no routes are listed, see [Troubleshooting](TROUBLESHOOTING.md#step-4-is-the-gateway-advertising-the-default-route).

Then check from the Azure side:

```sh
az network vhub bgpconnection list --resource-group rg-ntsk-gw --vhub-name <vhub-name> -o table
```

Expected: `ProvisioningState` = `Succeeded`, `PeerIp` = the gateway's LAN IP (`terraform output nva_ge2_private_ips`), `PeerAsn` = 400.

## Checking the SSE Monitor

On the gateway:

```sh
docker ps --filter name=sse_monitor          # launcher container should be Up
pgrep -fa sse_monitor.sh                     # exactly one monitor process
tail -50 /var/log/sse_monitor.log
```

The log shows `Tunnel Count=N` every 10 seconds. `N` is the number of IPsec tunnels to Netskope that are up. When it drops to 0, the log shows `ACTION: Tunnels Down. Retracting default route...`; when tunnels return, it shows `ACTION: Tunnels Up. Re-advertising default route...`. If the count stays at 0 for a long time, the problem is between the gateway and Netskope (activation, internet access from the WAN side), not with BGP.

## Monitoring Recommendations

- **Azure Monitor**: CPU, network in/out and the VM Availability metric for the gateway VMs. Alert on availability < 100% and sustained CPU > 80%.
- **NSG flow logs** on `nsg-nva-public` and `nsg-nva-private` if you need traffic visibility.
- **Netskope SD-WAN portal**: gateway status, tunnel state and policy hits.
- **SSE monitor log**: the `Tunnel Count` line is the fastest health indicator for the Netskope side.
