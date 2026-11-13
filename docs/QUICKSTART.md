# Quick Start

The shortest path to a working deployment. Each step tells you what you are doing and what success looks like. If anything here is unfamiliar — what `terraform apply` does, what a `.tfvars` file is, why there are two folders — read the [Deployment Guide](DEPLOYMENT_GUIDE.md) instead; it covers the same steps with explanations.

Expect about 45 minutes end to end, most of it waiting for Azure to build the Virtual WAN hub.

## What You Need First

- **Tools**: Terraform >= 1.3, Azure CLI (`az`), `jq`, and an SSH key pair (`ssh-keygen` if you don't have one). macOS is the tested platform.
- **Azure**: a subscription where you have Contributor rights.
- **Netskope**: your tenant URL (e.g. `example.infiot.net`), a REST API token (SD-WAN portal → Accounts → REST API), and a **gateway policy already created** in the portal — Terraform looks it up by name and will not create one.
- **Marketplace terms accepted** for the Netskope gateway image. One command, once per subscription:
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_2_x
  ```

## 1. Log in to Azure

```sh
az login
az account set --subscription "YOUR-SUBSCRIPTION-ID"
```

Terraform and the helper scripts both reuse this login.

## 2. Phase 1 — Build the Virtual WAN (`vwan-lab/`)

Copy the settings template and fill in four values:

```sh
git clone <repository-url>
cd terraform-netskopebwan-azure-vhub/vwan-lab
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
location            = "westeurope"       # Azure region
resource_group_name = "rg-ntsk-gw"       # created for you
ssh_public_key_path = "~/.ssh/id_rsa.pub"
ssh_source_address  = "1.2.3.4/32"      # your public IP (curl -s ifconfig.me) — restricts SSH to the test VMs
```

Then:

```sh
terraform init                                  # downloads the Azure plugin — once
terraform plan  -var-file=terraform.tfvars      # preview; nothing is created yet
terraform apply -var-file=terraform.tfvars      # type "yes" when asked
```

> **This takes 15–30 minutes**, almost all of it on `azurerm_virtual_hub.lab: Still creating...`. That is normal. Don't press Ctrl-C. If it does time out, wait for the hub to finish in the portal and run the same `apply` again.

When it finishes, grab the three values Phase 2 needs:

```sh
terraform output virtual_hub_id
terraform output virtual_router_ips
terraform output virtual_router_asn
```

## 3. Phase 2 — Deploy the Netskope Gateway (`vwan-lab-nva/`)

```sh
cd ../vwan-lab-nva
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars`. Paste the Phase 1 values, point it at the same resource group and region, and name your Netskope policy:

```hcl
# From Phase 1
virtual_hub_id      = "/subscriptions/.../virtualHubs/<vhub-name>"
virtual_router_ips  = ["10.0.0.70", "10.0.0.69"]
virtual_router_asn  = 65515
vhub_address_prefix = "10.0.0.0/24"

resource_group_name     = "rg-ntsk-gw"    # same as Phase 1
location                = "westeurope"     # same as Phase 1
nva_spoke_address_space = "10.3.0.0/24"   # new range for the gateway; must not overlap hub or spokes

gateway_count   = 1
gateway_prefix  = "ntsk-gw"
gateway_bgp_asn = 400
gateway_policy  = "<your-policy-name>"     # must already exist on the tenant
gateway_role    = "hub"

vm_size     = "Standard_DS11_v2"           # Gen1-compatible — see Deployment Guide
accept_plan = false                        # true only if you skipped the terms command above
```

Secrets go in environment variables, not in the file. Run these in the same terminal:

```sh
export TF_VAR_netskope_tenant_url="your-tenant.infiot.net"
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
export TF_VAR_admin_password='YourOsPassword123!'   # single quotes — zsh mangles ! inside double quotes
```

Then:

```sh
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

This takes 10–15 minutes. Near the end you'll see Terraform run two scripts on the new VM (`null_resource.bgp_config`, then `null_resource.sse_monitor`); the first waits for the VM to boot, so a minute or two of "waiting for VM" messages is expected.

> If `plan` fails mentioning `netskopebwan_policy`, the policy name is wrong. If it fails with an authentication error, check the tenant URL and token.

## 4. Check It Works

Terraform prints ready-made check commands:

```sh
terraform output bgp_verify_commands
```

The key one shows BGP status from inside the gateway, without SSH:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

You are looking for **four neighbours with a time in the `Up/Down` column** (not `Active` or `Idle`):

```
Neighbor        V    AS  MsgRcvd  MsgSent  Up/Down     State/PfxRcd
10.0.0.69       4  65515    114     103    01:37:44     3      ← hub router
10.0.0.70       4  65515    122     111    01:40:26     3      ← hub router
169.254.0.38    4   400     116     109    01:40:33     6      ← Netskope overlay (IPsec up)
169.254.0.39    4   400     111     113    01:40:31     6      ← Netskope overlay (IPsec up)
```

The gateway should also appear as activated in the Netskope SD-WAN portal.

If the hub neighbours aren't up after a couple of minutes, follow the flowchart in [Troubleshooting](TROUBLESHOOTING.md).

> **Don't be alarmed**: if you look at a spoke's effective routes in Azure, `0.0.0.0/0` will not be there even though the gateway is advertising it. Virtual WAN deliberately withholds a BGP-learned default route from spokes unless Routing Intent is configured, which Netskope's gateway can't use. See [Architecture — Routing Behaviour](ARCHITECTURE.md#routing-behaviour).

## Next Steps

- [Deployment Guide](DEPLOYMENT_GUIDE.md) — the same steps with every setting explained, plus teardown
- [Architecture](ARCHITECTURE.md) — what was built and how the pieces connect
- [Operations](OPERATIONS.md) — changing things afterwards
- [Troubleshooting](TROUBLESHOOTING.md) — when the BGP summary doesn't look like the one above
