#------------------------------------------------------------------------------
#  Input Variables — Netskope BWAN Azure
#------------------------------------------------------------------------------

###########################
## Azure Network Config  ##
###########################

variable "azure_network_config" {
  description = "Azure VNet and resource group configuration"
  type = object({
    subscription_id     = optional(string, "")
    location            = string                       # Azure region, e.g. "eastus"
    resource_group_name = string                       # Resource group to deploy into
    create_resource_group = optional(bool, true)       # Set false to use existing RG
    create_vnet         = optional(bool, true)
    vnet_id             = optional(string, "")         # Use existing VNet if create_vnet = false
    vnet_cidr           = optional(string, "")
  })
}

variable "tags" {
  description = "Common tags applied to all Azure resources"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
  }
}

######################
## Azure VM Config  ##
######################

variable "azure_vm_config" {
  description = "Azure virtual machine configuration"
  type = object({
    vm_size        = optional(string, "Standard_D2s_v3")
    admin_username = optional(string, "netskope")
    # SSH public key for OS-level access. The Netskope gateway admin password
    # is set separately via netskope_gateway_config.gateway_password.
    ssh_public_key = optional(string, "")
    # OS-level admin password. Required by Azure when ssh_public_key is empty.
    # Must meet Azure complexity: 12-123 chars, 3 of: uppercase, lowercase, number, special.
    # This is separate from netskope_gateway_config.gateway_password (Netskope app password).
    admin_password = optional(string, "")
    # Netskope BWAN Azure Marketplace image coordinates.
    # Confirmed via: az vm image list --publisher netskopebwan --all -o table
    # Only one version is currently available (6.2.5). Use "latest" to auto-pick newest.
    image_publisher = optional(string, "netskopebwan")
    image_offer     = optional(string, "netskope-unified-sase-virtual-gateway")
    image_sku       = optional(string, "netskope-unified-sase-virtual-gateway-r6_2_x")
    image_version   = optional(string, "6.2.5")
    # The Netskope BWAN image has a purchase plan — terms must be accepted before first deploy.
    # Set accept_plan = true to have Terraform accept them, or pre-accept with:
    #   az vm image terms accept \
    #     --publisher netskopebwan \
    #     --offer netskope-unified-sase-virtual-gateway \
    #     --plan netskope-unified-sase-virtual-gateway-r6_2_x
    accept_plan     = optional(bool, true)
  })
  default = {}
}

#############################
## Azure Route Server      ##
#############################

variable "azure_route_server" {
  description = <<-EOT
    Azure Route Server configuration. Route Server replaces AWS Transit Gateway (TGW Connect)
    for BGP peering with Netskope BWAN gateway VMs.

    Route Server ASN is fixed at 65515 by Azure (not configurable).
    Route Server always advertises two peer IPs for redundancy.

    route_server_subnet_cidr: Must be a /27 or larger, named "RouteServerSubnet".
    Leave empty to auto-compute from vnet_cidr (works when subnet_size = 28).
  EOT
  type = object({
    route_server_subnet_cidr = optional(string, "")
    branch_to_branch_traffic = optional(bool, true)
  })
  default = {}
}

##############################
## Gateway Count Variables  ##
##############################

variable "gateway_count" {
  description = "Number of Netskope BWAN gateways to deploy (2 for a resilient pair)"
  type        = number
  default     = 2

  validation {
    condition     = var.gateway_count >= 1 && var.gateway_count <= 8
    error_message = "gateway_count must be between 1 and 8."
  }
}

variable "gateway_prefix" {
  description = "Naming prefix for auto-generated gateway identifiers"
  type        = string
  default     = "az-gw"
}

variable "gateway_role" {
  description = "Role assigned to all gateways (e.g. hub, spoke)"
  type        = string
  default     = "hub"
}

variable "subnet_size" {
  description = "Subnet prefix length for auto-generated gateway subnets (default /28)"
  type        = number
  default     = 28
}

##########################
## Deployment Variables ##
##########################

variable "environment" {
  description = "Environment prefix for resource naming (e.g. prod, staging, dev)"
  type        = string
  default     = "netskope"
}

###########################
## Netskope Tenant       ##
###########################

variable "netskope_tenant" {
  description = "Netskope Tenant Details"
  type = object({
    deployment_name = string                          # Used in resource naming (e.g. "my-corp-prod")
    tenant_url      = optional(string, "")
    tenant_token    = optional(string, "")
    tenant_bgp_asn  = optional(string, "400")         # Gateway-side BGP ASN; must not be 65515
  })
}

variable "netskope_tenant_url" {
  description = "Netskope tenant URL. Overrides netskope_tenant.tenant_url. Set via TF_VAR_netskope_tenant_url."
  type        = string
  default     = ""
}

variable "netskope_tenant_token" {
  description = "Netskope REST API token. Overrides netskope_tenant.tenant_token. Set via TF_VAR_netskope_tenant_token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "netskope_gateway_config" {
  description = "Netskope Gateway configuration (shared across all gateways)"
  type = object({
    gateway_password = optional(string, "infiot")
    gateway_policy   = optional(string, "test")
    gateway_model    = optional(string, "iXVirtual")
    dns_primary      = optional(string, "8.8.8.8")
    dns_secondary    = optional(string, "8.8.4.4")
    # CIDRs to route via the LAN interface. Should include any Azure VNet CIDRs
    # or on-prem CIDRs that gateway VMs need to reach via the LAN.
    static_routes    = optional(list(string), [])
    wan_mtu          = optional(number, 1500)
  })
  default = {}
}
