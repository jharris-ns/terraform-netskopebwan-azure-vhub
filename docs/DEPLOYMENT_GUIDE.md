# Deployment Guide

This guide describes, step by step, how to deploy Netskope SD-WAN gateways into an Azure Virtual WAN. It assumes that you have used Azure before but have little or no Terraform experience. If you already know Terraform and only need the commands, use the [Quick Start](QUICKSTART.md) instead.

## Before You Begin

### Role of Terraform

Terraform reads a set of `.tf` files that describe the Azure and Netskope resources that are required, compares that description with what exists, and then creates, changes or deletes resources to match. You do not create anything manually in the Azure portal. You edit a small settings file and run three commands, and Terraform performs the remaining work.

The three commands you will use are:

| Command | Purpose |
|---|---|
| `terraform init` | Downloads the providers (the plugins that communicate with Azure and the Netskope API). Run once per folder, and again if you change provider versions. |
| `terraform plan` | Shows the changes Terraform would make, without making them. Review this before every apply. |
| `terraform apply` | Makes the changes. Terraform shows the plan again and asks you to type `yes`. |

Terraform records what it created in a file named `terraform.tfstate` in the same folder. Do not delete or edit this file, and do not commit it to git, because it contains secrets. See [State Management](STATE_MANAGEMENT.md) when you are ready to move it to shared storage.

### Two-Phase Folder Structure

This project is deployed in two phases, each in its own folder with its own state:

1. **`vwan-lab/`** builds the Virtual WAN: a hub and two small spoke networks with a test VM in each. This takes 15–30 minutes. Most of that time is spent waiting for Azure to build the hub.
2. **`vwan-lab-nva/`** builds the Netskope gateway in a third spoke and connects it to the hub with BGP.

The phases are separate so that the hub (slow to build, rarely changed) can remain deployed while the gateway (fast to build, often changed during testing) is rebuilt as often as required. The only link between the phases is three values, printed at the end of Phase 1, which you copy into the settings file for Phase 2.

### Settings files: `example.tfvars` and `terraform.tfvars`

Each folder has an `example.tfvars` file, a template that lists every setting with safe placeholder values. Copy it to `terraform.tfvars`, which is the file Terraform reads, and edit that copy. `terraform.tfvars` is gitignored because it holds values specific to your environment.

Secret settings (API token, passwords) are **not** stored in `terraform.tfvars`. They are passed as environment variables instead. Terraform reads these automatically when the variable name starts with `TF_VAR_`. This is described in Phase 2.

### Required Local Tools

- **Terraform** 1.3 or newer — check with `terraform version`
- **Azure CLI** (`az`) — check with `az version`. Terraform uses it to log in, and Phase 2 also uses it directly to run scripts on the gateway VM.
- **`jq`** — a JSON tool used by one of the helper scripts. Install with `brew install jq` on macOS.
- **An SSH key pair** — Phase 1 puts your public key on the test VMs. If you do not have one, run `ssh-keygen` and accept the defaults. The public key will be at `~/.ssh/id_rsa.pub` (or `id_ed25519.pub`).
- **macOS or Linux shell.** The project is developed and tested on macOS. The Phase 2 scripts use the macOS form of `sed -i ''`, which GNU `sed` on Linux does not accept, so those lines must be adjusted before running `terraform apply` from Linux.

### Azure and Netskope Requirements

- An Azure subscription where you have **Contributor** on the resource group or subscription (see [RBAC Permissions](RBAC_PERMISSIONS.md)).
- A **Netskope SD-WAN tenant** and a **REST API token** for it. In the SD-WAN portal, go to Accounts → REST API to create one. Also note your tenant URL, for example `example.infiot.net`.
- A **gateway policy** already created in the SD-WAN portal. Terraform finds the policy by name and does not create one. If the name is wrong, `terraform plan` fails immediately with a "policy not found" error. This is a safe, early failure.
- **Marketplace terms accepted** for the Netskope gateway image. This is required once per subscription. Either run the command below now, or set `accept_plan = true` in Phase 2 so that Terraform accepts the terms:
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_3_x
  ```

## Step 1 — Log in to Azure

```sh
az login
az account set --subscription "YOUR-SUBSCRIPTION-ID"
az account show --query "{name:name, id:id}" -o table   # confirm you're in the right one
```

Both Terraform and the helper scripts reuse this login, so it is required only once per session. If you are setting up a pipeline rather than working interactively, see [Service principal authentication](#service-principal-authentication) at the end.

## Step 2 — Phase 1: Build the Virtual WAN

### 2.1 Create your settings file

```sh
cd vwan-lab
cp example.tfvars terraform.tfvars
```

Open `terraform.tfvars` in an editor. The defaults are suitable for a lab. Review the following lines:

```hcl
location            = "westeurope"          # Azure region for everything
resource_group_name = "rg-ntsk-gw"          # Terraform creates this group
ssh_public_key_path = "~/.ssh/id_rsa.pub"   # your SSH public key
ssh_source_address  = "1.2.3.4/32"          # your public IP — only this address may SSH to the test VMs
```

To find your public IP, run `curl -s ifconfig.me`. Leaving `ssh_source_address` as `"*"` opens SSH on the test VMs to the whole internet. This is acceptable for a few hours of testing, but not for a deployment that remains in place. The test VMs are currently created without a public IP, so this rule only takes effect if one is added.

The hub and spoke address ranges (`10.0.0.0/24`, `10.1.0.0/24`, `10.2.0.0/24`) can remain unchanged unless they conflict with networks you intend to connect later. If you change them, make sure that no ranges overlap. Azure does not attach a spoke whose range overlaps the hub or another spoke.

### 2.2 Initialise, plan, apply

```sh
terraform init
terraform plan -var-file=terraform.tfvars
```

The plan lists every resource to be created (around 20) and ends with `Plan: N to add, 0 to change, 0 to destroy`. Nothing has been created at this point. Errors at this stage are almost always caused by a typing error in `terraform.tfvars` or a missing SSH key file.

```sh
terraform apply -var-file=terraform.tfvars
```

Type `yes` when prompted, then wait. The virtual hub takes **15–30 minutes** to provision, and the output shows `azurerm_virtual_hub.lab: Still creating...` for most of that time. This is normal. **Do not press Ctrl-C**: interrupting Terraform during creation can leave the state file inconsistent with Azure. If the apply times out, check the hub's provisioning state in the Azure portal, wait for it to finish, then run the same `terraform apply` again. Terraform continues from where it stopped.

### 2.3 Save the outputs for Phase 2

When the apply finishes, it prints a set of outputs. Three of them are required:

```sh
terraform output virtual_hub_id
terraform output virtual_router_ips
terraform output virtual_router_asn
```

Save these values. You will enter them in the Phase 2 settings file. Phase 2 also needs `vhub_address_prefix`. This is not an output: use the hub address range set in the Phase 1 `terraform.tfvars` (default `10.0.0.0/24`). `virtual_router_ips` is a list of two IPs; `virtual_router_asn` is always `65515`.

### 2.4 Verify the deployment (optional)

The hub should already route between the two spokes with no extra configuration. To confirm, query Azure for the routes that a spoke receives:

```sh
az network vhub get-effective-routes \
  --resource-group rg-ntsk-gw \
  --name <vhub-name> \
  --resource-type HubVirtualNetworkConnection \
  --resource-id "$(terraform output -json hub_connection_ids | jq -r .spoke1)" -o table
```

You should see the other spoke's range (`10.2.0.0/24`) listed with its hub connection as the next hop. The test VMs have no public IP. To test connectivity, run a ping from one test VM to the other with Azure Run Command, for example `az vm run-command invoke -g rg-ntsk-gw -n vm-spoke1-test01 --command-id RunShellScript --scripts "ping -c 3 10.2.0.4"`.

## Step 3 — Phase 2: Deploy the Netskope Gateway

### 3.1 Create your settings file

```sh
cd ../vwan-lab-nva
cp example.tfvars terraform.tfvars
```

Open `terraform.tfvars` and complete it from top to bottom:

**Enter the Phase 1 outputs.** Replace the placeholder values with the values you saved in step 2.3:

```hcl
virtual_hub_id      = "/subscriptions/.../resourceGroups/rg-ntsk-gw/providers/Microsoft.Network/virtualHubs/vhub-ntsk-gw-westeurope-01"
virtual_router_ips  = ["10.0.0.70", "10.0.0.69"]
virtual_router_asn  = 65515
vhub_address_prefix = "10.0.0.0/24"     # same as the hub range you used in Phase 1
```

**Match Phase 1.** These must be the same region and resource group you used in Phase 1, because the gateway is deployed into the group that Phase 1 created:

```hcl
resource_group_name = "rg-ntsk-gw"
location            = "westeurope"
```

**Choose the gateway network.** This is a new range for the gateway's spoke. It must not overlap the hub or the Phase 1 spokes:

```hcl
nva_spoke_address_space = "10.3.0.0/24"
```

**Set the number of gateways.** Start with one. You can increase this later and re-apply. Terraform adds the extra gateway without changing the first:

```hcl
gateway_count  = 1
gateway_prefix = "ntsk-gw"          # gateways are named ntsk-gw-1, ntsk-gw-2, ...
```

**Netskope settings.** The policy name must exactly match a policy that already exists in your SD-WAN portal:

```hcl
gateway_bgp_asn = 400               # leave as is unless 400 is already used on your network; must not be 65515
gateway_policy  = "my-policy-name"
gateway_role    = "hub"
```

**VM size and Marketplace terms.**

```hcl
vm_size     = "Standard_DS11_v2"
accept_plan = false                 # set true if you did NOT run `az vm image terms accept` earlier
```

The Netskope image is a "Generation 1" image, so the VM size must support Gen1. `Standard_DS11_v2` supports it. Newer sizes ending in `v5`/`v6` often do not and fail with `VMMarketplaceInvalidInput`. Before changing the size, check that it is available in your region:

```sh
az vm list-skus --location westeurope --size Standard_DS11 --zone true -o table
```

### 3.2 Set the secrets as environment variables

These are never written to `terraform.tfvars`. Run the following commands in the terminal from which you will run Terraform. The variables remain set until you close the terminal:

```sh
export TF_VAR_netskope_tenant_url="example.infiot.net"       # your tenant URL, no https://
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
export TF_VAR_admin_password='YourOsPassword123!'           # password for the VM's OS account
export TF_VAR_gateway_password='YourGwPassword123!'         # optional — Netskope console password, default "infiot"
```

Two details often cause errors:

- **Use single quotes around passwords** if they contain `!`. In zsh (the default macOS shell) a `!` inside double quotes triggers history expansion and changes the value without warning.
- `admin_password` must satisfy Azure's complexity rules: 12–123 characters with at least three of uppercase, lowercase, digit and symbol. If it does not, VM creation fails with a clear error. Correct the password and re-apply.

The variable names must be exact: Terraform maps `TF_VAR_admin_password` to the variable `admin_password`, and likewise for the others. If you open a new terminal, you must export them again.

### 3.3 Initialise, plan, apply

```sh
terraform init
terraform plan -var-file=terraform.tfvars
```

If `plan` fails with an error about `netskopebwan_policy`, the `gateway_policy` name does not match a policy on your tenant. If it fails with an authentication error, re-check the tenant URL and token.

```sh
terraform apply -var-file=terraform.tfvars
```

Type `yes`. This phase takes approximately 10–15 minutes. Terraform creates resources in the following order, and each stage appears in the output:

1. The gateway's spoke network, subnets and security groups
2. The gateway's record in the Netskope portal (gateway, interfaces, BGP peers, activation token)
3. Public IP and network interfaces
4. The connection from the new spoke to the hub, then a deliberate 60-second pause (Azure reports the connection as ready shortly before it is ready)
5. The hub-side BGP connection for the gateway
6. The VM, which boots from the Netskope Marketplace image
7. A script run *on* the VM through Azure Run Command (`null_resource.bgp_config`) that activates the gateway, writes the BGP configuration and restarts the gateway software. This step waits for the VM to finish booting, so it polls for one or two minutes first
8. A second script (`null_resource.sse_monitor`) that installs the tunnel-health monitor

Step 7 prints the gateway's BGP summary at the end. If BGP peers are not yet up, the script retries once and then finishes with a warning instead of failing, because the sessions often establish a minute later. Use the verification steps below to check.

## Step 4 — Verify the Gateway

Terraform prints a set of ready-to-run commands as an output:

```sh
terraform output bgp_verify_commands
```

The most important command is the BGP summary. It runs a command on the VM, so SSH access is not required:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

The expected result is **four neighbours**, all with a time (not a state such as `Active` or `Idle`) in the `Up/Down` column:

- Two with AS `65515`. These are the hub's router IPs. An established session means the gateway and the hub are exchanging routes.
- Two with addresses starting `169.254.0.`. These are Netskope's overlay peers. An established session means the IPsec tunnels to Netskope are up.

Then confirm the gateway is advertising only the default route to the hub:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show ip bgp neighbors 10.0.0.69 advertised-routes'"
```

Expected: a single line for `0.0.0.0/0` with metric `10`, and `Total number of prefixes 1`.

Finally, the gateway should appear as activated, with both interfaces up, in the Netskope SD-WAN portal.

If any result does not match, see [Troubleshooting](TROUBLESHOOTING.md). It is organised as a step-by-step flowchart that starts from the hub.

> **Default route in the spokes:** after Phase 2, the effective routes on a spoke connection (as in step 2.4) should include `0.0.0.0/0`, learned from the gateway. The spoke connections use `internet_security_enabled = true`, so the hub passes the gateway's default route to the spokes. Routing Intent is not required. See [Architecture — Routing Behaviour](ARCHITECTURE.md#routing-behaviour).

## Changing the Deployment

**Changing a setting.** Edit `terraform.tfvars`, run `terraform plan` to see the effect, then `terraform apply`. Terraform only changes what is needed. Note that changing the VM size recreates the VM.

**Adding a gateway.** Set `gateway_count = 2` and apply. The new gateway gets its own subnets, VM, portal entry and hub BGP connection. The existing gateway is not changed. The limit is 4 (Microsoft documents 8 BGP peers per hub).

**Re-running the gateway scripts.** The two Run Command steps only re-run when something they depend on changes. If you edit the BGP configuration inside `run_command.tf`, or the gateway loses its configuration after a restart, force them to re-run:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

`-replace` tells Terraform to treat that one resource as if it needs recreating. For a `null_resource`, "recreating" means only that its script runs again.

**If you rebuild the hub.** Destroying and recreating Phase 1 gives the hub new router IPs and a new ID. Copy the new outputs into `vwan-lab-nva/terraform.tfvars` and apply Phase 2 again. Further day-2 procedures are in [Operations](OPERATIONS.md).

## Removing the Deployment

Destroy the phases in the reverse order of deployment, because the gateway depends on the hub:

```sh
cd vwan-lab-nva && terraform destroy -var-file=terraform.tfvars    # needs the TF_VAR_ secrets exported
cd ../vwan-lab   && terraform destroy -var-file=terraform.tfvars
```

Each command asks you to type `yes`. The Phase 2 destroy also removes the gateway from your Netskope portal (the policy you created manually is not removed). Hub deletion in Phase 1 is slow, like its creation. If you added anything to the hub manually in the portal (for example, an extra BGP connection), remove it first, or the destroy fails with a dependency error.

## Reference: Settings

Settings beyond those covered in the steps above are rarely needed, but every setting is listed here.

### Phase 1 — `vwan-lab/terraform.tfvars`

| Setting | Default | Description |
|---|---|---|
| `ssh_public_key_path` | *(required)* | Path to your SSH public key, installed on the test VMs |
| `location` | `"eastus"` | Azure region for everything in Phase 1 |
| `resource_group_name` | `"rg-vwan-lab"` | Resource group Terraform creates |
| `vwan_name` | `"vwan-lab-01"` | Name of the Virtual WAN (always Standard tier — Basic does not support BGP peering) |
| `vhub_name` | `"vhub-lab-eastus-01"` | Name of the hub |
| `vhub_address_prefix` | `"10.0.0.0/24"` | Hub's own address range; /24 is the Azure minimum |
| `spoke1_address_space` / `spoke1_subnet_prefix` | `10.1.0.0/24` / `10.1.0.0/26` | Spoke 1 network and its VM subnet |
| `spoke2_address_space` / `spoke2_subnet_prefix` | `10.2.0.0/24` / `10.2.0.0/26` | Spoke 2 network and its VM subnet |
| `vm_size` | `"Standard_B2s"` | Size of the two test VMs |
| `admin_username` | `"azureuser"` | Login name on the test VMs |
| `ssh_source_address` | `"*"` | Source address allowed to SSH to the test VMs; set to your IP as `x.x.x.x/32` |

### Phase 2 — `vwan-lab-nva/terraform.tfvars`

| Setting | Default | Description |
|---|---|---|
| `virtual_hub_id` | *(required)* | From Phase 1 output |
| `virtual_router_ips` | *(required)* | From Phase 1 output — the two hub router IPs the gateway peers with |
| `virtual_router_asn` | `65515` | Hub router's BGP AS number; Azure fixes this at 65515 |
| `vhub_address_prefix` | `"10.0.0.0/24"` | Hub range; the gateway routes this via its LAN interface so that BGP traffic does not leave through the WAN interface |
| `subscription_id` | `""` | Leave empty to use the subscription selected by `az login` |
| `resource_group_name` | `"rg-ntsk-gw"` | Must be the Phase 1 group |
| `location` | `"westeurope"` | Must be the Phase 1 region |
| `nva_spoke_address_space` | `"10.3.0.0/24"` | Gateway spoke network; the gateway's WAN and LAN subnets are allocated from it as /28 subnets |
| `subnet_size` | `28` | Size of those subnets |
| `gateway_count` | `2` | Number of gateways (1–4). The example file sets 1. |
| `gateway_prefix` | `"ntsk-gw"` | Name prefix; gateways become `ntsk-gw-1`, `ntsk-gw-2`… |
| `gateway_role` | `"hub"` | Role shown in the Netskope portal |
| `gateway_bgp_asn` | `400` | The gateway's BGP AS number; anything except 65515 |
| `gateway_policy` | *(required)* | Name of an existing Netskope policy |
| `vm_size` | `"Standard_DS11_v2"` | Must be a Gen1-capable size |
| `accept_plan` | `false` | `true` allows Terraform to accept the Marketplace terms |

### Phase 2 — environment variables

| Variable | Required | Description |
|---|---|---|
| `TF_VAR_netskope_tenant_url` | Yes | Your tenant URL, e.g. `example.infiot.net` (with or without `https://`) |
| `TF_VAR_netskope_tenant_token` | Yes | REST API token from the SD-WAN portal |
| `TF_VAR_admin_password` | Yes | OS login password for the gateway VM (user `netskope`); Azure complexity rules apply |
| `TF_VAR_gateway_password` | No | Netskope console password; defaults to `infiot` |

### Service principal authentication

For pipelines, create a service principal with Contributor instead of using `az login`, and export its credentials. Both the Terraform provider and the Azure CLI need these credentials:

```sh
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."
export ARM_TENANT_ID="..."
export ARM_SUBSCRIPTION_ID="..."

az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
az account set --subscription "$ARM_SUBSCRIPTION_ID"
```

The `ARM_*` variables are read by Terraform; the `az login` line is for the Run Command scripts. See [RBAC Permissions — CI/CD](RBAC_PERMISSIONS.md#running-from-a-pipeline) for the rest of the runner requirements.
