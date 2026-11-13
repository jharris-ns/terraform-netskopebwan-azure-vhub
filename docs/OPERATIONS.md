# Operations

What to do after the deployment is up: changing it, fixing it, checking it. Written for someone who can run `terraform apply` but may not know Terraform's finer points — each procedure explains why the commands are what they are.

Unless stated otherwise, run commands from `vwan-lab-nva/` with your `TF_VAR_` secrets exported (see [Deployment Guide — secrets](DEPLOYMENT_GUIDE.md#32-set-the-secrets-as-environment-variables)). If you opened a new terminal since you deployed, export them again first.

## The One Terraform Concept You Need: `-replace`

Most changes are simple: edit `terraform.tfvars`, run `terraform plan` to see the effect, run `terraform apply`. Terraform works out the difference and changes only that.

Two resources are different. The BGP configuration and the SSE monitor are not Azure resources — they are *scripts that Terraform ran on the gateway VM once*. Terraform calls these `null_resource`s and only re-runs them if one of their inputs changes. If you want to run one again (for example, after editing the script or after the gateway lost its configuration), you tell Terraform to pretend it needs recreating:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

`-replace` means "destroy and recreate this one thing". For a `null_resource`, "recreate" just means run the script again — nothing in Azure is touched. The `["ntsk-gw-1"]` part names which gateway; use `["ntsk-gw-2"]` for the second, and so on. You will see this pattern throughout this page.

## Scaling: Adding or Removing a Gateway

Change one number and apply:

```hcl
# terraform.tfvars
gateway_count = 2   # was 1
```

```sh
terraform plan  -var-file=terraform.tfvars    # should show only additions
terraform apply -var-file=terraform.tfvars
```

The new gateway gets the next pair of subnets, its own VM, public IP, Netskope portal entry and hub BGP connection, and both scripts run on it. The existing gateway is not touched — the plan should show `0 to change, 0 to destroy`; if it shows anything being destroyed, stop and read the plan.

Reducing the count destroys the highest-numbered gateway(s), including their portal entries.

**Limit**: 1–4 gateways. Microsoft documents a maximum of 8 BGP peers per virtual hub.

## Replacing a Gateway VM

Use this if the VM is unhealthy, or you want a different VM size (changing `vm_size` in `terraform.tfvars` and applying does the same thing — Terraform recreates the VM because the size can't be changed in place).

```sh
# 1. Recreate the VM
terraform apply -replace='azurerm_linux_virtual_machine.nva["ntsk-gw-1"]' -var-file=terraform.tfvars

# 2. Re-run both scripts on the new VM
terraform apply \
  -replace='null_resource.bgp_config["ntsk-gw-1"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-1"]' \
  -var-file=terraform.tfvars
```

Step 2 is needed because a fresh VM has none of the configuration the scripts installed, but Terraform doesn't know that — the scripts' inputs haven't changed. The gateway's entry in the Netskope portal (name, interfaces, BGP peers) is kept; the new VM activates against the same entry.

## Re-Running the BGP Configuration

When: you edited the FRR/BGP settings in `run_command.tf`; the hub's router IPs changed; or the gateway lost its hub route after a manual restart (see Troubleshooting).

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
```

What the script does on the gateway, in order: re-activates against your Netskope tenant (harmless if already active), writes the BGP configuration file, adds the route that sends hub traffic out of the LAN interface, restarts the gateway software, re-adds the route, then waits and prints `show bgp summary`. It takes 2–3 minutes and the gateway's BGP sessions drop and re-form during it — plan for that if the gateway is carrying traffic.

If you changed `virtual_router_ips` in `terraform.tfvars`, you don't need `-replace` — those are inputs to the script, so Terraform re-runs it automatically.

## Re-Deploying the SSE Monitor

The SSE monitor is a small service on the gateway that watches the IPsec tunnels to Netskope and tells BGP to advertise the default route only while at least one tunnel is up.

Terraform re-deploys it automatically when `scripts/sse_monitor.sh` changes (it tracks the file's checksum). It does **not** notice changes to `sse_monitor.service` or `sse_monitor.logrotate`, so after editing those, force it:

```sh
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

To redo everything on every gateway in one go, list each resource:

```sh
terraform apply \
  -replace='null_resource.bgp_config["ntsk-gw-1"]' \
  -replace='null_resource.bgp_config["ntsk-gw-2"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-1"]' \
  -replace='null_resource.sse_monitor["ntsk-gw-2"]' \
  -var-file=terraform.tfvars
```

## If You Rebuild the Hub (Phase 1)

Destroying and recreating the Virtual WAN hub gives it a new resource ID and new router IPs. Phase 2 has copies of the old values in its `terraform.tfvars`, so:

```sh
cd vwan-lab
terraform output virtual_hub_id virtual_router_ips virtual_router_asn
```

Paste the new values into `vwan-lab-nva/terraform.tfvars`, then in `vwan-lab-nva/` run `terraform plan` and `terraform apply`. Terraform will update the hub connection and BGP connections, update the BGP peers in the Netskope portal, and re-run the BGP script (its inputs changed). No `-replace` needed.

## Rotating the Netskope API Token

1. Create a new REST API token in the SD-WAN portal (Accounts → REST API)
2. `export TF_VAR_netskope_tenant_token="NEW_TOKEN"`
3. Run `terraform plan` — it should say `No changes`. The token is only used to talk to the API; it isn't stored in any resource.

## Getting Onto a Gateway

You usually don't need to. Azure Run Command lets you execute a command on the VM from your own machine and see the output, with no SSH and no open ports needed:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

Replace the quoted command with anything from the [gateway command reference](TROUBLESHOOTING.md#gateway-commands-quick-reference). `terraform output bgp_verify_commands` prints the most useful ones already filled in with your names.

If you do want a shell, SSH to the gateway's public IP as the OS user `netskope` with the `TF_VAR_admin_password` you set:

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

How to read it:

- The two `65515` rows are the hub's router IPs. A time in `Up/Down` means the session is established; the number on the right is how many routes the hub is sending us (hub range plus the spokes).
- The two `169.254.0.x` rows are Netskope's overlay peers. If these are established, the IPsec tunnels to Netskope are up. If they show `Active`/`Connect`, the gateway can't reach Netskope — and the SSE monitor will have withdrawn the default route, which is the correct response.

Then check what the gateway is telling the hub:

```sh
docker exec infiot_spoke vtysh -c "show ip bgp neighbors 10.0.0.69 advertised-routes"
```

Expected: exactly one route, `0.0.0.0/0`, metric `10`. If you see spoke ranges listed too, or nothing at all, see [Troubleshooting](TROUBLESHOOTING.md#step-4-is-the-gateway-advertising-the-default-route).

And from the Azure side:

```sh
az network vhub bgpconnection list --resource-group rg-ntsk-gw --vhub-name <vhub-name> -o table
```

Expected: `ProvisioningState` = `Succeeded`, `PeerIp` = the gateway's LAN IP (`terraform output nva_ge2_private_ips`), `PeerAsn` = 400.

## Watching the SSE Monitor

On the gateway:

```sh
systemctl status sse_monitor                 # should be active (running)
tail -50 /var/log/sse_monitor.log
```

The log shows `Tunnel Count=N` every 10 seconds. `N` is how many IPsec tunnels to Netskope are up. When it drops to 0 you'll see `ACTION: Tunnels Down. Retracting default route...`; when tunnels return, `ACTION: Tunnels Up. Re-advertising default route...`. If the count is 0 for a long time, the problem is between the gateway and Netskope (activation, internet access from the WAN side), not with BGP.

## Monitoring Recommendations

- **Azure Monitor**: CPU, network in/out and the VM Availability metric for the gateway VMs. Alert on availability < 100% and sustained CPU > 80%.
- **NSG flow logs** on `nsg-nva-public` and `nsg-nva-private` if you need traffic visibility.
- **Netskope SD-WAN portal**: gateway status, tunnel state and policy hits.
- **SSE monitor log**: the `Tunnel Count` line is the quickest health signal for the Netskope side.
