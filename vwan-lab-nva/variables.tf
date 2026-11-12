#------------------------------------------------------------------------------
#  Input Variables
#
#  Phase 1 vhub outputs (virtual_hub_id, virtual_router_ips, virtual_router_asn,
#  vhub_address_prefix) are passed in as variables. Copy them from:
#    cd ../vwan-lab && terraform output
#------------------------------------------------------------------------------

#-- Azure auth ----------------------------------------------------------------

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. Leave empty to use the az login default."
  default     = ""
}

#-- Phase 1 vhub outputs (consumed as inputs here) ---------------------------

variable "virtual_hub_id" {
  type        = string
  description = "Resource ID of the virtual hub from Phase 1. Used for hub connection and BGP connection."
}

variable "virtual_router_ips" {
  type        = list(string)
  description = "BGP router IPs of the virtual hub (two IPs). From Phase 1 output virtual_router_ips."
}

variable "virtual_router_asn" {
  type        = number
  description = "BGP ASN of the virtual hub router. Always 65515 for Azure Virtual WAN."
  default     = 65515
}

variable "vhub_address_prefix" {
  type        = string
  description = "Address prefix of the virtual hub (e.g. 10.0.0.0/24). Used to route BGP traffic via the LAN interface."
  default     = "10.0.0.0/24"
}

#-- Resource group and location -----------------------------------------------

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy NVA resources into. Must already exist (created by Phase 1)."
  default     = "rg-ntsk-gw"
}

variable "location" {
  type        = string
  description = "Azure region. Must match Phase 1."
  default     = "westeurope"
}

#-- NVA spoke network ---------------------------------------------------------

variable "nva_spoke_address_space" {
  type        = string
  description = "Address space for the NVA spoke VNet. Must not overlap hub or Phase 1 spokes."
  default     = "10.3.0.0/24"
}

variable "subnet_size" {
  type        = number
  description = "Subnet prefix length for auto-carved NVA subnets (GE1 and GE2 per gateway)."
  default     = 28
}

#-- Gateway scaling -----------------------------------------------------------

variable "gateway_count" {
  type        = number
  description = "Number of NVA gateways to deploy. Each gets its own GE1/GE2 subnets, VM, and vhub BGP connection."
  default     = 2

  validation {
    condition     = var.gateway_count >= 1 && var.gateway_count <= 4
    error_message = "gateway_count must be between 1 and 4."
  }
}

variable "gateway_prefix" {
  type        = string
  description = "Naming prefix for gateways. Keys are generated as {prefix}-1, {prefix}-2, etc."
  default     = "ntsk-gw"
}

#-- VM ------------------------------------------------------------------------

variable "vm_size" {
  type        = string
  description = "VM size for the NVA. Must be Gen1-compatible — the Netskope BWAN image is Gen1 only."
  default     = "Standard_DS11_v2"
}

variable "accept_plan" {
  type        = bool
  description = "Set true to have Terraform accept the Netskope Marketplace image terms. Set false if pre-accepted with `az vm image terms accept ...`."
  default     = false
}

variable "admin_password" {
  type        = string
  description = "OS-level admin password for the NVA VM. Set via TF_VAR_admin_password. Must meet Azure complexity rules."
  sensitive   = true
}

#-- Netskope secrets (set via environment variables, not terraform.tfvars) ----

variable "netskope_tenant_url" {
  type        = string
  description = "Netskope tenant URL (e.g. example.infiot.net). Set via TF_VAR_netskope_tenant_url."
  sensitive   = true
}

variable "netskope_tenant_token" {
  type        = string
  description = "Netskope REST API token. Set via TF_VAR_netskope_tenant_token."
  sensitive   = true
}

#-- Netskope gateway config ---------------------------------------------------

variable "gateway_bgp_asn" {
  type        = number
  description = "BGP ASN for the NVA gateways. Must not be 65515 (reserved by the vhub router)."
  default     = 400
}

variable "gateway_password" {
  type        = string
  description = "Netskope gateway console password (separate from OS admin_password). Set via TF_VAR_gateway_password."
  sensitive   = true
  default     = "infiot"
}

variable "gateway_policy" {
  type        = string
  description = "Name of an existing policy on the Netskope SD-WAN tenant. Must be created in the portal before deployment."
}

variable "gateway_role" {
  type        = string
  description = "Gateway role assigned in the Netskope portal."
  default     = "hub"
}
