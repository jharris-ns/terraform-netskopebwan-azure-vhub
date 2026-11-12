#------------------------------------------------------------------------------
#  Example: Deploy 2 Netskope BWAN gateways in a new Azure VNet
#
#  Copy this file to terraform.tfvars and fill in the values marked
#  REPLACE-WITH-YOUR-*.
#
#  Secrets (tenant_url, tenant_token) must NOT be placed in terraform.tfvars.
#  Set them as environment variables instead (see Authentication section in
#  docs/DEPLOYMENT_GUIDE.md):
#
#    export TF_VAR_netskope_tenant_url="example.infiot.net"
#    export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
#
#  Azure credentials are picked up automatically from `az login` or a
#  service principal (ARM_CLIENT_ID / ARM_CLIENT_SECRET env vars).
#------------------------------------------------------------------------------

# Azure VNet and resource group configuration.
# - location: Azure region for all resources (e.g. "westeurope", "eastus")
# - resource_group_name: name of the resource group to create or use
# - create_resource_group: set false if the resource group already exists
# - create_vnet: set false and provide vnet_id to use an existing VNet
# - vnet_cidr: CIDR block for the VNet; gateway subnets are auto-carved from this
azure_network_config = {
  subscription_id       = "REPLACE-WITH-YOUR-SUBSCRIPTION-ID"
  location              = "eastus"
  resource_group_name   = "rg-netskope-bwan"
  create_resource_group = true
  create_vnet           = true
  vnet_cidr             = "10.100.0.0/22"
}

# Number of gateways to deploy.
gateway_count = 2

# Naming prefix for gateway identifiers.
# Gateway keys are generated as: {gateway_prefix}-1, {gateway_prefix}-2, etc.
# VM names become: {gateway_prefix}-{n}-{deployment_name}
gateway_prefix = "az-gw"

# Optional overrides (defaults shown) — uncomment to customise:
# gateway_role = "hub"       # role assigned to all gateways (hub or spoke)
# subnet_size  = 28          # prefix length for auto-generated gateway subnets

# Azure VM configuration.
# Confirmed working: Standard_D8ds_v4 (8 vCPU, 32 GB RAM, Gen1/Gen2-compatible).
# The Netskope BWAN Marketplace image is Gen1; Gen2-only SKUs will fail.
# Check availability in your region with:
#   az vm list-skus --location <region> --size Standard_D8ds_v4 --zone true -o table
#
# admin_password: OS-level admin password (separate from gateway_password below).
# Must meet Azure complexity: 12–123 chars, 3 of: uppercase, lowercase, number, special.
#
# accept_plan: set true to have Terraform accept the Marketplace image terms on
# first deploy. Alternatively pre-accept with:
#   az vm image terms accept \
#     --publisher netskopebwan \
#     --offer netskope-unified-sase-virtual-gateway \
#     --plan netskope-unified-sase-virtual-gateway-r6_2_x
azure_vm_config = {
  accept_plan    = false        # set true if marketplace terms not yet accepted
  vm_size        = "Standard_D8ds_v4"
  admin_password = "REPLACE-WITH-YOUR-OS-PASSWORD"
}

# Azure Route Server configuration.
# Route Server provisions in ~15–20 minutes; its ASN is fixed at 65515 by Azure.
#
# route_server_subnet_cidr: pin this value explicitly to prevent CIDR drift if
# gateway_count ever changes. Must be /27 or larger, within vnet_cidr.
# Auto-computed formula: cidrsubnet(vnet_cidr, 27 - vnet_prefix_len, gateway_count)
# With the defaults above (vnet_cidr = 10.100.0.0/22, gateway_count = 2):
#   the auto-computed value is 10.100.0.64/27.
# Pin it to prevent the subnet from shifting on future gateway_count changes.
azure_route_server = {
  route_server_subnet_cidr = "10.100.0.64/27"
}

# Netskope tenant configuration.
# - deployment_name: appended to VM names and Azure resource names (e.g. "my-corp-prod")
# - tenant_bgp_asn: BGP ASN for the gateways; must not be 65515 (reserved by Route Server)
#
# Secrets (tenant_url, tenant_token) are set via environment variables — do not add them here.
netskope_tenant = {
  deployment_name = "REPLACE-WITH-YOUR-DEPLOYMENT-NAME"
  tenant_bgp_asn  = "400"
}

# Netskope gateway configuration shared across all gateways.
# - gateway_policy: name of an existing policy on the Netskope SD-WAN tenant.
#     Must be created in the SD-WAN portal before deployment.
# - gateway_password: Netskope application console password (not the OS admin password).
# - static_routes: CIDRs to route via the LAN interface on each gateway.
#     Include any Azure VNet CIDRs, on-prem CIDRs, or RFC 1918 ranges the
#     gateway needs to reach via its LAN NIC (not via the default WAN route).
# - wan_mtu: MTU for the Netskope overlay/WAN interface (default: 1500).
netskope_gateway_config = {
  gateway_policy   = "REPLACE-WITH-YOUR-POLICY-NAME"
  gateway_password = "REPLACE-WITH-YOUR-GW-PASSWORD"
  static_routes    = ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"]
  # wan_mtu        = 1500   # lower if experiencing fragmentation
}

# Common tags applied to all Azure resources.
tags = {
  ManagedBy   = "terraform"
  Environment = "production"
  Project     = "netskope-bwan-azure"
}

#------------------------------------------------------------------------------
#  Alternative: Use an existing VNet
#  Replace the azure_network_config block above with:
#
#  azure_network_config = {
#    subscription_id       = "REPLACE-WITH-YOUR-SUBSCRIPTION-ID"
#    location              = "westeurope"
#    resource_group_name   = "rg-netskope-bwan"
#    create_resource_group = false
#    create_vnet           = false
#    vnet_id               = "/subscriptions/.../resourceGroups/.../providers/Microsoft.Network/virtualNetworks/my-vnet"
#    vnet_cidr             = "10.100.0.0/22"   # must match the actual VNet CIDR
#  }
#
#  When using an existing VNet, ensure the RouteServerSubnet does not already
#  exist — Terraform will create it. If it already exists, import it first:
#    terraform import 'azurerm_subnet.route_server' <subnet-resource-id>
#------------------------------------------------------------------------------
