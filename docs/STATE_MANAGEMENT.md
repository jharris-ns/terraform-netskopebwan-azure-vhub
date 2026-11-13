# State Management

## What State Is and Why It Matters

Every time Terraform creates something, it records what it made — resource IDs, IP addresses, settings — in a file called `terraform.tfstate`. On the next run it compares that file with your `.tf` files to decide what to change. Lose the file and Terraform forgets everything it built; it would try to create it all again and fail on name clashes. Corrupt it and `apply` may do the wrong thing.

State also contains secrets: the gateway activation tokens, the OS password, private IPs. Treat it like a credentials file.

Right now both workspaces keep state **locally** — `vwan-lab/terraform.tfstate` and `vwan-lab-nva/terraform.tfstate` — plus a `.backup` of the previous version. That's fine for one person working from one laptop. It is not fine when a second person, or a pipeline, needs to run Terraform: they'd have no state and would try to rebuild everything. Both files are gitignored, so don't try to share them through git either.

## Moving State to Azure Storage

The standard fix is to keep state in an Azure Storage blob. Everyone (and every pipeline) then reads and writes the same copy, and Azure locks the blob while someone is applying so two runs can't collide.

### 1. Create a place to keep it

Use a separate resource group so state outlives the lab:

```sh
az group create --name rg-terraform-state --location westeurope

# Storage account name must be globally unique, lowercase letters and digits, 3–24 chars
az storage account create \
  --name <storageaccountname> \
  --resource-group rg-terraform-state \
  --location westeurope \
  --sku Standard_LRS \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2

# Versioning keeps old copies so you can roll back a bad state
az storage account blob-service-properties update \
  --account-name <storageaccountname> \
  --resource-group rg-terraform-state \
  --enable-versioning true

az storage container create \
  --name tfstate \
  --account-name <storageaccountname> \
  --auth-mode login
```

Your identity needs **Storage Blob Data Contributor** on the container (Contributor on the subscription is *not* enough for data access):

```sh
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az storage account show -n <storageaccountname> -g rg-terraform-state --query id -o tsv)"
```

### 2. Tell each workspace to use it

Add a `backend.tf` to each folder. The two workspaces must use **different `key` values** — otherwise they'd overwrite each other:

```hcl
# vwan-lab/backend.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<storageaccountname>"
    container_name       = "tfstate"
    key                  = "vwan-lab.tfstate"
  }
}
```

```hcl
# vwan-lab-nva/backend.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<storageaccountname>"
    container_name       = "tfstate"
    key                  = "vwan-lab-nva.tfstate"
  }
}
```

### 3. Move the existing state

In each folder:

```sh
terraform init -migrate-state
```

Terraform notices the backend has changed, asks "Do you want to copy existing state to the new backend?", and you answer `yes`. Then confirm nothing was lost:

```sh
terraform plan -var-file=terraform.tfvars    # should report "No changes"
```

Once that's clean, delete the local `terraform.tfstate` and `terraform.tfstate.backup` so nobody picks up a stale copy by mistake.

### 4. Authentication

The backend logs in the same way the provider does — your `az login`, or `ARM_*` variables for a service principal. The identity needs the Storage Blob Data Contributor role from step 1 in addition to its deployment permissions.

## Optional: Stop Copying Phase 1 Values by Hand

With both states in the same storage account, Phase 2 could read the hub ID and router IPs straight from Phase 1's state instead of you copying them into `terraform.tfvars`:

```hcl
data "terraform_remote_state" "vwan" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<storageaccountname>"
    container_name       = "tfstate"
    key                  = "vwan-lab.tfstate"
  }
}
# then use data.terraform_remote_state.vwan.outputs.virtual_hub_id etc.
```

This is **not** implemented in the current code — `virtual_hub_id` and `virtual_router_ips` are ordinary variables — but it's the natural next step once state is remote.

## Good Habits

- Keep blob versioning on. If an apply goes wrong you can restore the previous state version from the portal.
- Never hand-edit state. If you must fix it, use `terraform state` commands (`list`, `show`, `rm`, `mv`).
- Don't run `apply` in two terminals at once against local state; with the Azure backend, locking prevents this for you.
- `terraform.tfvars`, `*.tfstate` and `*.tfstate.backup` are gitignored — keep them that way.

## Other Backends

HCP Terraform (Terraform Cloud) or any other backend with locking also works. Note that the Phase 2 scripts run *on the machine executing `terraform apply`*, so a remote-execution backend would need the Azure CLI, `jq` and `python3` available in its runner.
