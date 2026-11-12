#------------------------------------------------------------------------------
#  Provider Configuration
#
#  Azure authentication: set ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID,
#  ARM_SUBSCRIPTION_ID env vars, or use `az login` for interactive auth.
#
#  Azure Run Command (local-exec) requires the az CLI to be installed and
#  authenticated. Run `az login` or set service principal env vars before
#  running `terraform apply`.
#------------------------------------------------------------------------------

locals {
  # Standalone env vars override object fields; strip https:// if present
  tenant_url_raw = trimprefix(trimprefix(
    coalesce(var.netskope_tenant_url, var.netskope_tenant.tenant_url),
    "https://"), "http://")
  tenant_url   = local.tenant_url_raw
  tenant_token = coalesce(var.netskope_tenant_token, var.netskope_tenant.tenant_token)

  # Build API URL from tenant URL (insert ".api." subdomain)
  tenant_url_slice     = split(".", local.tenant_url_raw)
  tenant_api_url_slice = concat(slice(local.tenant_url_slice, 0, 1), ["api"], slice(local.tenant_url_slice, 1, length(local.tenant_url_slice)))
  tenant_api_url       = "https://${join(".", local.tenant_api_url_slice)}"
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_network_config.subscription_id
}

provider "netskopebwan" {
  baseurl  = local.tenant_api_url
  apitoken = local.tenant_token
}
