# State Management

## Purpose of Terraform State

Each time Terraform creates a resource, it records the details (resource IDs, IP addresses, settings) in a file called `terraform.tfstate`. On the next run it compares that file with your `.tf` files to decide what to change. If the file is lost, Terraform has no record of the resources it created. It would try to create them all again and fail on name conflicts. If the file is corrupted, `apply` may make incorrect changes.

State also contains secrets: the gateway activation tokens, the OS password, private IPs. Protect it in the same way as a credentials file.

Currently both workspaces keep state **locally**, in `vwan-lab/terraform.tfstate` and `vwan-lab-nva/terraform.tfstate`, plus a `.backup` of the previous version. This is suitable for one person working from one laptop. It is not suitable when a second person, or a pipeline, needs to run Terraform: they would have no state and would try to rebuild everything. Both files are gitignored, so do not share them through git either.

## Moving State to Azure Storage

The standard solution is to keep state in an Azure Storage blob. Every user and every pipeline then reads and writes the same copy, and Azure locks the blob during an apply so that two runs cannot conflict.

### 1. Create the storage account

Use a separate resource group so that the state is not deleted with the lab:

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

### 2. Configure each workspace

Add a `backend.tf` to each folder. The two workspaces must use **different `key` values**. Otherwise they would overwrite each other:

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

Terraform detects that the backend has changed and asks "Do you want to copy existing state to the new backend?". Answer `yes`. Then confirm that nothing was lost:

```sh
terraform plan -var-file=terraform.tfvars    # should report "No changes"
```

When the plan reports no changes, delete the local `terraform.tfstate` and `terraform.tfstate.backup` so that an outdated copy is not used by mistake.

### 4. Authentication

The backend authenticates in the same way as the provider: with your `az login`, or with `ARM_*` variables for a service principal. The identity needs the Storage Blob Data Contributor role from step 1 in addition to its deployment permissions.

## Optional: Read Phase 1 Outputs Automatically

With both states in the same storage account, Phase 2 could read the hub ID and router IPs directly from the Phase 1 state, instead of a manual copy into `terraform.tfvars`:

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

This is **not** implemented in the current code: `virtual_hub_id` and `virtual_router_ips` are ordinary variables. It is the logical next step once state is remote.

## Recommended Practices

- Keep blob versioning enabled. If an apply causes a problem, you can restore the previous state version from the portal.
- Never edit state by hand. If it must be corrected, use `terraform state` commands (`list`, `show`, `rm`, `mv`).
- Do not run `apply` in two terminals at the same time against local state. With the Azure backend, locking prevents this.
- `terraform.tfvars`, `*.tfstate` and `*.tfstate.backup` are gitignored. Keep them gitignored.

## Other Backends

HCP Terraform (Terraform Cloud) or any other backend with locking also works. Note that the Phase 2 scripts run *on the machine executing `terraform apply`*, so a remote-execution backend would need the Azure CLI, `jq` and `python3` available in its runner.
