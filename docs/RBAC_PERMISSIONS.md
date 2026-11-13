# RBAC Permissions

Who needs what permissions in Azure to deploy this project, and how to set it up for a pipeline.

## The Short Version

One identity — yours, or a service principal for a pipeline — needs the built-in **Contributor** role on the resource group (or the subscription, if Terraform is creating the resource group). That covers everything both phases create: Virtual WAN, hub, hub connections and BGP connections, VNets, NSGs, public IPs, NICs, VMs, Marketplace agreements and Run Command.

The gateway VMs themselves need **no** Azure permissions. Nothing in this project creates a managed identity or role assignment; the VMs never call the Azure API.

To check what you have:

```sh
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

## Two Things That Are Easy to Miss

### Resource providers

Azure features are grouped into "resource providers" that must be switched on once per subscription. Most subscriptions already have these, but a new one may not:

```sh
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.MarketplaceOrdering   # needed to accept the image terms
```

Registration takes a minute or two; `az provider show -n Microsoft.Network --query registrationState` should say `Registered`.

### Marketplace terms

The Netskope gateway is a Marketplace image, and Azure requires someone to accept its terms once per subscription before a VM can be created from it. Two ways to do that:

- **By hand, once** (recommended): run the command below with an account that has Contributor, and leave `accept_plan = false` in Phase 2.
  ```sh
  az vm image terms accept \
    --publisher netskopebwan \
    --offer netskope-unified-sase-virtual-gateway \
    --plan netskope-unified-sase-virtual-gateway-r6_2_x
  ```
- **Let Terraform do it**: set `accept_plan = true`. The Terraform identity then also needs rights to the `Microsoft.MarketplaceOrdering` provider — included in Contributor.

## Running From a Pipeline

Interactive `az login` doesn't work in CI, so you use a **service principal** — an identity for automation. Create one with Contributor on the resource group and note its credentials:

```sh
az ad sp create-for-rbac --name sp-ntsk-vwan-lab \
  --role Contributor \
  --scopes /subscriptions/<sub-id>/resourceGroups/rg-ntsk-gw
```

Then in the pipeline, two logins are needed — this is the part people miss:

1. **Terraform's own login** reads these environment variables:
   ```sh
   export ARM_CLIENT_ID="<appId>"
   export ARM_CLIENT_SECRET="<password>"
   export ARM_TENANT_ID="<tenant>"
   export ARM_SUBSCRIPTION_ID="<sub-id>"
   ```
2. **The Azure CLI login**, because the Phase 2 scripts call `az` directly (separately from Terraform) to run commands on the gateway:
   ```sh
   az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
   az account set --subscription "$ARM_SUBSCRIPTION_ID"
   ```

The runner also needs:

- **Tools**: Terraform, Azure CLI, `jq`, `python3` (used to assemble the SSE monitor payload), `tar` and `base64`.
- **macOS-compatible `sed`**: the Phase 2 scripts use `sed -i ''`, which GNU `sed` on Linux rejects. Either run on macOS or adapt those lines in `run_command.tf`.
- **Secrets** stored in the pipeline's secret store and exported as `TF_VAR_netskope_tenant_url`, `TF_VAR_netskope_tenant_token`, `TF_VAR_admin_password` and optionally `TF_VAR_gateway_password`.
- **State backend access** — see [State Management](STATE_MANAGEMENT.md); the service principal needs **Storage Blob Data Contributor** on the state container.

## If You Can't Use Contributor

Some organisations require a narrower custom role. The resource types involved are listed in [Architecture — Resource Inventory](ARCHITECTURE.md#reference-resource-inventory); the corresponding permission families are `Microsoft.Resources/subscriptions/resourceGroups/*`, `Microsoft.Network/virtualWans/*`, `Microsoft.Network/virtualHubs/*` (which includes hub connections and BGP connections), `Microsoft.Network/virtualNetworks/*`, `Microsoft.Network/networkSecurityGroups/*`, `Microsoft.Network/publicIPAddresses/*`, `Microsoft.Network/networkInterfaces/*`, `Microsoft.Compute/virtualMachines/*` (including `runCommand/action`), plus `Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/*` if `accept_plan = true`.

Build the exact list from Microsoft's [resource provider operations reference](https://learn.microsoft.com/en-us/azure/role-based-access-control/resource-provider-operations) and validate it with `terraform plan` and a test `apply`. This project has only been tested with Contributor; the list above is a starting point, not a tested role definition.
