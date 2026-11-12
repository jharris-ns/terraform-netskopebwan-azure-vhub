#------------------------------------------------------------------------------
#  Provider Configuration
#
#  Azure: `az login` or ARM_* env vars.
#  Netskope: set via environment variables — do NOT put in terraform.tfvars:
#    export TF_VAR_netskope_tenant_url="your-tenant.infiot.net"
#    export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
#------------------------------------------------------------------------------

locals {
  # Strip https:// if present; insert .api. subdomain for the REST API base URL.
  tenant_url_raw       = trimprefix(trimprefix(var.netskope_tenant_url, "https://"), "http://")
  tenant_url           = local.tenant_url_raw
  tenant_url_slice     = split(".", local.tenant_url_raw)
  tenant_api_url_slice = concat(slice(local.tenant_url_slice, 0, 1), ["api"], slice(local.tenant_url_slice, 1, length(local.tenant_url_slice)))
  tenant_api_url       = "https://${join(".", local.tenant_api_url_slice)}"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}

provider "netskopebwan" {
  baseurl  = local.tenant_api_url
  apitoken = var.netskope_tenant_token
}
