# Deployment Guide

This guide walks you through deploying Netskope SD-WAN gateways into an Azure Virtual WAN, step by step, and assumes you have used Azure before but have little or no Terraform experience. If you already know Terraform and just want the commands, use the [Quick Start](QUICKSTART.md) instead.

## Before You Start

### What Terraform does here

Terraform reads a set of `.tf` files that describe the Azure and Netskope resources we want, compares that description with what exists, and then creates, changes or deletes resources to match. You do not create anything in the Azure portal by hand — you edit a small settings file, run three commands, and Terraform does the rest.

The three commands you will use are:

| Command | What it does |
|---|---|
| `terraform init` | Downloads the providers (the plugins that talk to Azure and to the Netskope API). Run once per folder, and again if you ever change provider versions. |
| `terraform plan` | Shows what Terraform *would* do, without doing it. Read this before every apply. |
| `terraform apply` | Does it. Terraform shows the plan again and asks you to type `yes`. |

Terraform remembers what it created in a file called `terraform.tfstate` in the same folder. Do not delete or edit it, and do not commit it to git — it contains secrets. See [State Management](STATE_MANAGEMENT.md) when you are ready to move it to shared storage.

### Why there are two folders

This project is deployed in two phases, each in its own folder with its own state:

1. **`vwan-lab/`** builds the Virtual WAN itself: a hub and two small spoke networks with a test VM in each. This takes 15–30 minutes, almost all of it waiting for Azure to build the hub.
2. **`vwan-lab-nva/`** builds the Netskope gateway in a third spoke and connects it to the hub with BGP.

The split exists so that the hub (slow to build, rarely changed) can stay up while the gateway (fast to build, often changed during testing) is rebuilt as many times as you like. The only link between them is that you copy three values printed at the end of Phase 1 into the settings file for Phase 2.

### Settings files: `example.tfvars` and `terraform.tfvars`

Each folder has an `example.tfvars` — a template of every setting with safe placeholder values. You copy it to `terraform.tfvars`, which is the file Terraform actually reads, and edit that copy. `terraform.tfvars` is gitignored because it holds values specific to your environment.

Settings that are secrets (API token, passwords) are **not** put in `terraform.tfvars` at all. They are passed as environment variables instead, which Terraform picks up automatically when the variable name starts with `TF_VAR_`. That is covered in Phase 2.

### Tools you need on your machine

- **Terraform** 1.3 or newer — check with `terraform version`
- **Azure CLI** (`az`) — check with `az version`. Terraform uses it to log in, and Phase 2 also uses it directly to run scripts on the gateway VM.
- **`jq`** — a small JSON tool used by one of the helper scripts. Install with `brew install jq` on macOS.
- **An SSH key pair** — Phase 1 puts your public key on the test VMs. If you don't have one, run `ssh-keygen` and accept the defaults; the public key will be at `~/.ssh/id_rsa.pub` (or `id_ed25519.pub`).
- **macOS or Linux shell.** The project is developed and tested on macOS. The Phase 2 scripts use the macOS form of `sed -i ''`, which GNU `sed` on Linux does not accept, so running `terraform apply` from Linux needs those lines adjusted first.

### Things you need in Azure and Netskope

- An Azure subscription where you have **Contributor** on the resource group or subscription (see [RBAC Permissions](RBAC_PERMISSIONS.md)).
- A **Netskope SD-WAN tenant** and a **REST API token** for it. In the SD-WAN portal, go to Accounts → REST API to create one. Note your tenant URL too, e.g. `example.infiot.net`.
- A **gateway policy** already created in the SD-WAN portal. Terraform looks the policy up by name; it will not create one. If the name is wrong, `terraform plan` fails immediately with a "policy not found" error — which is a safe, early failure.
- **Marketplace terms accepted** for the Netskope gateway image. This is a one-off per subscription. Either run the command below now, or set `accept_plan = true` in Phase 2 and let Terraform do it:
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_2_x
  ```

## Step 1 — Log in to Azure

```sh
az login
az account set --subscription "YOUR-SUBSCRIPTION-ID"
az account show --query "{name:name, id:id}" -o table   # confirm you're in the right one
```

Both Terraform and the helper scripts reuse this login, so you only do it once per session. If you are setting up a pipeline rather than working interactively, see [Service principal authentication](#service-principal-authentication) at the end.

## Step 2 — Phase 1: Build the Virtual WAN

### 2.1 Create your settings file

```sh
cd vwan-lab
cp example.tfvars terraform.tfvars
```

Open `terraform.tfvars` in an editor. The defaults are fine for a lab; the lines you should look at are:

```hcl
location            = "westeurope"          # Azure region for everything
resource_group_name = "rg-ntsk-gw"          # Terraform creates this group
ssh_public_key_path = "~/.ssh/id_rsa.pub"   # your SSH public key
ssh_source_address  = "1.2.3.4/32"          # your public IP — only this address may SSH to the test VMs
```

To find your public IP: `curl -s ifconfig.me`. Leaving `ssh_source_address` as `"*"` opens SSH on the test VMs to the whole internet; fine for a few hours of testing, not for anything that stays up.

The hub and spoke address ranges (`10.0.0.0/24`, `10.1.0.0/24`, `10.2.0.0/24`) can stay as they are unless they clash with networks you intend to connect later. If you change them, keep all ranges non-overlapping — Azure refuses to attach a spoke whose range overlaps the hub or another spoke.

### 2.2 Initialise, plan, apply

```sh
terraform init
terraform plan -var-file=terraform.tfvars
```

The plan lists every resource to be created (around 20) and ends with `Plan: N to add, 0 to change, 0 to destroy`. Nothing has happened yet. If you see errors, they are almost always a typo in `terraform.tfvars` or a missing SSH key file.

```sh
terraform apply -var-file=terraform.tfvars
```

Type `yes` when prompted. Now wait. The virtual hub takes **15–30 minutes** to provision and the output will sit on `azurerm_virtual_hub.lab: Still creating...` for most of that time. This is normal. **Do not press Ctrl-C** — interrupting Terraform mid-create can leave the state file out of step with Azure. If the apply does time out, check the hub's provisioning state in the Azure portal, wait for it to finish, then run the same `terraform apply` again; Terraform picks up where it left off.

### 2.3 Save the outputs for Phase 2

When the apply finishes it prints a block of outputs. You need three of them:

```sh
terraform output virtual_hub_id
terraform output virtual_router_ips
terraform output virtual_router_asn
```

Copy these somewhere — you will paste them into the Phase 2 settings file. `virtual_router_ips` is a list of two IPs; `virtual_router_asn` is always `65515`.

### 2.4 Check it worked (optional)

The hub should already be routing between the two spokes with no extra configuration. Confirm by asking Azure what routes a spoke sees:

```sh
az network vhub get-effective-routes \
  --resource-group rg-ntsk-gw \
  --name <vhub-name> \
  --resource-type HubVirtualNetworkConnection \
  --resource-id "$(terraform output -raw hub_connection_ids | jq -r .spoke1)" -o table
```

You should see the other spoke's range (`10.2.0.0/24`) listed with its hub connection as the next hop. You can also SSH to a test VM (`terraform output vm_public_ips`) as `azureuser` and ping the other test VM's private IP.

## Step 3 — Phase 2: Deploy the Netskope Gateway

### 3.1 Create your settings file

```sh
cd ../vwan-lab-nva
cp example.tfvars terraform.tfvars
```

Open `terraform.tfvars`. Work through it top to bottom:

**Paste the Phase 1 outputs.** Replace the placeholder values with what you saved in step 2.3:

```hcl
virtual_hub_id      = "/subscriptions/.../resourceGroups/rg-ntsk-gw/providers/Microsoft.Network/virtualHubs/vhub-ntsk-gw-westeurope-01"
virtual_router_ips  = ["10.0.0.70", "10.0.0.69"]
virtual_router_asn  = 65515
vhub_address_prefix = "10.0.0.0/24"     # same as the hub range you used in Phase 1
```

**Match Phase 1.** These must be the same region and resource group you used in Phase 1 — the gateway is deployed into the group Phase 1 created:

```hcl
resource_group_name = "rg-ntsk-gw"
location            = "westeurope"
```

**Choose the gateway network.** A new range for the gateway's spoke; it must not overlap the hub or the Phase 1 spokes:

```hcl
nva_spoke_address_space = "10.3.0.0/24"
```

**How many gateways.** Start with one. You can raise this later and re-apply; Terraform adds the extra gateway without touching the first:

```hcl
gateway_count  = 1
gateway_prefix = "ntsk-gw"          # gateways are named ntsk-gw-1, ntsk-gw-2, ...
```

**Netskope settings.** The policy name must match one that already exists in your SD-WAN portal, exactly:

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

The Netskope image is a "Generation 1" image, so the VM size must support Gen1. `Standard_DS11_v2` does. Newer sizes ending in `v5`/`v6` often do not and fail with `VMMarketplaceInvalidInput`. Before changing the size, check it is available in your region:

```sh
az vm list-skus --location westeurope --size Standard_DS11 --zone true -o table
```

### 3.2 Set the secrets as environment variables

These are never written to `terraform.tfvars`. Run the following in the same terminal you will run Terraform from (they last until you close it):

```sh
export TF_VAR_netskope_tenant_url="example.infiot.net"       # your tenant URL, no https://
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
export TF_VAR_admin_password='YourOsPassword123!'           # password for the VM's OS account
export TF_VAR_gateway_password='YourGwPassword123!'         # optional — Netskope console password, default "infiot"
```

Two details that catch people out:

- **Use single quotes around passwords** if they contain `!`. In zsh (the default macOS shell) a `!` inside double quotes triggers history expansion and silently mangles the value.
- `admin_password` must satisfy Azure's complexity rules: 12–123 characters with at least three of uppercase, lowercase, digit and symbol. If it doesn't, the VM creation fails with a clear error and you can fix it and re-apply.

The names matter: Terraform maps `TF_VAR_admin_password` to the variable `admin_password`, and so on. If you open a new terminal you need to export them again.

### 3.3 Initialise, plan, apply

```sh
terraform init
terraform plan -var-file=terraform.tfvars
```

If `plan` fails with an error about `netskopebwan_policy`, the `gateway_policy` name does not match a policy on your tenant. If it fails with an authentication error, re-check the tenant URL and token.

```sh
terraform apply -var-file=terraform.tfvars
```

Type `yes`. This phase takes roughly 10–15 minutes. Terraform creates things in this order, and you will see each stage scroll past:

1. The gateway's spoke network, subnets and security groups
2. The gateway's record in the Netskope portal (gateway, interfaces, BGP peers, activation token)
3. Public IP and network cards
4. The connection from the new spoke to the hub, then a deliberate 60-second pause (Azure reports the connection ready slightly before it actually is)
5. The hub-side BGP connection for the gateway
6. The VM itself, booting from the Netskope Marketplace image
7. A script run *on* the VM via Azure Run Command (`null_resource.bgp_config`) that activates the gateway, writes the BGP configuration and restarts the gateway software — this step waits for the VM to be fully booted, so expect it to poll for a minute or two first
8. A second script (`null_resource.sse_monitor`) that installs the tunnel-health monitor

Step 7 prints the gateway's BGP summary at the end. If BGP peers are not yet up, the script retries once and then finishes with a warning rather than failing — the sessions often come up a minute later. Check with the verification steps below.

## Step 4 — Check the Gateway Is Working

Terraform prints a set of ready-to-run commands as an output:

```sh
terraform output bgp_verify_commands
```

The most important is the BGP summary. It runs a command on the VM for you, so you don't need to SSH in:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

What you want to see are **four neighbours**, all with a time (not a word like `Active` or `Idle`) in the `Up/Down` column:

- Two with AS `65515` — these are the hub's router IPs. Established means the gateway and the hub are exchanging routes.
- Two with addresses starting `169.254.0.` — these are Netskope's own overlay peers. Established means the IPsec tunnels to Netskope are up.

Then confirm the gateway is advertising only the default route to the hub:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show ip bgp neighbors 10.0.0.69 advertised-routes'"
```

Expected: a single line for `0.0.0.0/0` with metric `10`, and `Total number of prefixes 1`.

Finally, the gateway should show as activated, with both interfaces up, in the Netskope SD-WAN portal.

If any of this does not match, go to [Troubleshooting](TROUBLESHOOTING.md) — it is organised as a step-by-step flowchart starting from the hub.

> **A result that looks wrong but isn't:** if you check the effective routes on a spoke connection (as in step 2.4) you will *not* see `0.0.0.0/0` there, even though the gateway is advertising it. Azure Virtual WAN deliberately does not push a BGP-learned default route into spoke networks unless a feature called Routing Intent is configured, and that feature needs the gateway to be a Microsoft-partner hub appliance, which Netskope is not. This is documented Azure behaviour, not a fault. See [Architecture — Routing Behaviour](ARCHITECTURE.md#routing-behaviour).

## Making Changes Later

**Changing a setting.** Edit `terraform.tfvars`, run `terraform plan` to see the effect, then `terraform apply`. Terraform only changes what is needed. Note that changing the VM size recreates the VM.

**Adding a gateway.** Set `gateway_count = 2` and apply. The new gateway gets its own subnets, VM, portal entry and hub BGP connection; the existing one is untouched. The limit is 4 (Microsoft documents 8 BGP peers per hub).

**Re-running the gateway scripts.** The two Run Command steps only re-run when something they depend on changes. If you edit the BGP configuration inside `run_command.tf`, or the gateway loses its configuration after a restart, force them to re-run:

```sh
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

`-replace` tells Terraform to treat that one resource as if it needs recreating. For a `null_resource`, "recreating" just means running its script again.

**If you rebuild the hub.** Destroying and recreating Phase 1 gives the hub new router IPs and a new ID. Copy the fresh outputs into `vwan-lab-nva/terraform.tfvars` and apply Phase 2 again. More day-2 procedures are in [Operations](OPERATIONS.md).

## Tearing It Down

Destroy in the reverse order you built, because the gateway depends on the hub:

```sh
cd vwan-lab-nva && terraform destroy -var-file=terraform.tfvars    # needs the TF_VAR_ secrets exported
cd ../vwan-lab   && terraform destroy -var-file=terraform.tfvars
```

Each asks you to type `yes`. Phase 2 destroy also removes the gateway from your Netskope portal (the policy you created by hand is left alone). Hub deletion in Phase 1 is slow, like its creation. If you added anything to the hub by hand in the portal (an extra BGP connection, for instance), remove it first or the destroy will fail on a dependency error.

## Reference: All Settings

You will rarely need anything beyond what the walkthrough covers, but every setting is listed here.

### Phase 1 — `vwan-lab/terraform.tfvars`

| Setting | Default | What it is |
|---|---|---|
| `ssh_public_key_path` | *(required)* | Path to your SSH public key, installed on the test VMs |
| `location` | `"eastus"` | Azure region for everything in Phase 1 |
| `resource_group_name` | `"rg-vwan-lab"` | Resource group Terraform creates |
| `vwan_name` | `"vwan-lab-01"` | Name of the Virtual WAN (always Standard tier — Basic cannot do BGP peering) |
| `vhub_name` | `"vhub-lab-eastus-01"` | Name of the hub |
| `vhub_address_prefix` | `"10.0.0.0/24"` | Hub's own address range; /24 is the Azure minimum |
| `spoke1_address_space` / `spoke1_subnet_prefix` | `10.1.0.0/24` / `10.1.0.0/26` | Spoke 1 network and its VM subnet |
| `spoke2_address_space` / `spoke2_subnet_prefix` | `10.2.0.0/24` / `10.2.0.0/26` | Spoke 2 network and its VM subnet |
| `vm_size` | `"Standard_B2s"` | Size of the two test VMs |
| `admin_username` | `"azureuser"` | Login name on the test VMs |
| `ssh_source_address` | `"*"` | Who may SSH to the test VMs; set to your IP as `x.x.x.x/32` |

### Phase 2 — `vwan-lab-nva/terraform.tfvars`

| Setting | Default | What it is |
|---|---|---|
| `virtual_hub_id` | *(required)* | From Phase 1 output |
| `virtual_router_ips` | *(required)* | From Phase 1 output — the two hub router IPs the gateway peers with |
| `virtual_router_asn` | `65515` | Hub router's BGP AS number; Azure fixes this at 65515 |
| `vhub_address_prefix` | `"10.0.0.0/24"` | Hub range; the gateway routes this via its LAN interface so BGP traffic doesn't go out the WAN side |
| `subscription_id` | `""` | Leave empty to use whatever `az login` selected |
| `resource_group_name` | `"rg-ntsk-gw"` | Must be the Phase 1 group |
| `location` | `"westeurope"` | Must be the Phase 1 region |
| `nva_spoke_address_space` | `"10.3.0.0/24"` | Gateway spoke network; the gateway's WAN and LAN subnets are carved from it as /28s |
| `subnet_size` | `28` | Size of those carved subnets |
| `gateway_count` | `2` | How many gateways (1–4). The example file sets 1. |
| `gateway_prefix` | `"ntsk-gw"` | Name prefix; gateways become `ntsk-gw-1`, `ntsk-gw-2`… |
| `gateway_role` | `"hub"` | Role shown in the Netskope portal |
| `gateway_bgp_asn` | `400` | The gateway's BGP AS number; anything except 65515 |
| `gateway_policy` | *(required)* | Name of an existing Netskope policy |
| `vm_size` | `"Standard_DS11_v2"` | Must be a Gen1-capable size |
| `accept_plan` | `false` | `true` lets Terraform accept the Marketplace terms for you |

### Phase 2 — environment variables

| Variable | Required | What it is |
|---|---|---|
| `TF_VAR_netskope_tenant_url` | Yes | Your tenant URL, e.g. `example.infiot.net` (with or without `https://`) |
| `TF_VAR_netskope_tenant_token` | Yes | REST API token from the SD-WAN portal |
| `TF_VAR_admin_password` | Yes | OS login password for the gateway VM (user `netskope`); Azure complexity rules apply |
| `TF_VAR_gateway_password` | No | Netskope console password; defaults to `infiot` |

### Service principal authentication

For pipelines, instead of `az login` create a service principal with Contributor and export its credentials. Both the Terraform provider and the Azure CLI need to know about it:

```sh
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."
export ARM_TENANT_ID="..."
export ARM_SUBSCRIPTION_ID="..."

az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
az account set --subscription "$ARM_SUBSCRIPTION_ID"
```

The `ARM_*` variables are read by Terraform; the `az login` line is for the Run Command scripts. See [RBAC Permissions — CI/CD](RBAC_PERMISSIONS.md#running-from-a-pipeline) for the rest of the runner requirements.
