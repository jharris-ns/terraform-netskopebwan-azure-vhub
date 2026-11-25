# Quick Start

This guide is the shortest path to a working deployment. Each step states its purpose and the expected result. If anything here is unfamiliar (what `terraform apply` does, what a `.tfvars` file is, why there are two folders), read the [Deployment Guide](DEPLOYMENT_GUIDE.md) instead. It covers the same steps with explanations.

The full process takes about 45 minutes. Most of that time is spent waiting for Azure to build the Virtual WAN hub.

## Prerequisites

- **Tools**: Terraform >= 1.3, Azure CLI (`az`), `jq`, and an SSH key pair (run `ssh-keygen` if you do not have one). macOS is the tested platform.
- **Azure**: a subscription where you have Contributor rights.
- **Netskope**: your tenant URL (e.g. `example.infiot.net`), a REST API token (SD-WAN portal → Accounts → REST API), and a **gateway policy already created** in the portal. Terraform finds the policy by name and does not create one.
- **Marketplace terms accepted** for the Netskope gateway image. Run this command once per subscription:
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_3_x
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

Then run:

```sh
terraform init                                  # downloads the Azure plugin — once
terraform plan  -var-file=terraform.tfvars      # preview; nothing is created yet
terraform apply -var-file=terraform.tfvars      # type "yes" when asked
```

> **This takes 15–30 minutes**. For most of that time the output shows `azurerm_virtual_hub.lab: Still creating...`. This is normal. Do not press Ctrl-C. If the apply times out, wait for the hub to finish in the portal and run the same `apply` again.

When the apply finishes, record the three output values that Phase 2 requires. Phase 2 also needs `vhub_address_prefix`. This is not an output: use the hub address range set in the Phase 1 `terraform.tfvars` (default `10.0.0.0/24`).

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

Edit `terraform.tfvars`. Enter the Phase 1 values, set the same resource group and region, and specify your Netskope policy:

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

Set secrets as environment variables, not in the file. Run these commands in the same terminal:

```sh
export TF_VAR_netskope_tenant_url="your-tenant.infiot.net"
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
export TF_VAR_admin_password='YourOsPassword123!'   # single quotes — zsh mangles ! inside double quotes
```

Then run:

```sh
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

This takes 10–15 minutes. Near the end, Terraform runs two scripts on the new VM (`null_resource.bgp_config`, then `null_resource.sse_monitor`). The first waits for the VM to boot, so "waiting for VM" messages are expected for one or two minutes.

> If `plan` fails with an error that mentions `netskopebwan_policy`, the policy name is wrong. If it fails with an authentication error, check the tenant URL and token.

## 4. Verify the Deployment

Terraform prints ready-to-run verification commands:

```sh
terraform output bgp_verify_commands
```

The most important command shows the BGP status from inside the gateway, without SSH:

```sh
az vm run-command invoke \
  --resource-group rg-ntsk-gw --name vm-ntsk-gw-1 \
  --command-id RunShellScript \
  --scripts "docker exec infiot_spoke vtysh -c 'show bgp summary'"
```

The expected result is **four neighbours with a time in the `Up/Down` column** (not `Active` or `Idle`):

```
Neighbor        V    AS  MsgRcvd  MsgSent  Up/Down     State/PfxRcd
10.0.0.69       4  65515    114     103    01:37:44     3      ← hub router
10.0.0.70       4  65515    122     111    01:40:26     3      ← hub router
169.254.0.38    4   400     116     109    01:40:33     6      ← Netskope overlay (IPsec up)
169.254.0.39    4   400     111     113    01:40:31     6      ← Netskope overlay (IPsec up)
```

The gateway should also appear as activated in the Netskope SD-WAN portal.

If the hub neighbours are not up after a few minutes, follow the flowchart in [Troubleshooting](TROUBLESHOOTING.md).

> **Expected behaviour**: the spokes receive `0.0.0.0/0` from the hub while the gateway advertises it, and spoke internet traffic then leaves through Netskope. See [Architecture — Routing Behaviour](ARCHITECTURE.md#routing-behaviour).

## Next Steps

- [Deployment Guide](DEPLOYMENT_GUIDE.md): the same steps with every setting explained, and how to remove the deployment
- [Architecture](ARCHITECTURE.md): what was built and how the components connect
- [Operations](OPERATIONS.md): changing the deployment afterwards
- [Troubleshooting](TROUBLESHOOTING.md): when the BGP summary does not match the one above
