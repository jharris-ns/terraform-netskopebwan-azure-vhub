#------------------------------------------------------------------------------
#  VNet, Subnets, NSGs, Route Tables, and Azure Route Server
#
#  Azure Route Server replaces AWS Transit Gateway Connect (GRE/BGP).
#  Route Server enables direct eBGP peering between the Netskope gateway
#  VMs (NVAs) and Azure — no GRE tunnel required.
#
#  Route Server ASN is 65515 (fixed by Azure, not configurable).
#  Route Server exposes two peer IPs from the RouteServerSubnet.
#------------------------------------------------------------------------------

# --- API propagation delay (mirrors aws vpc_api_delay) ---

resource "time_sleep" "vnet_api_delay" {
  # Wait for resource group to propagate across Azure ARM nodes before creating
  # child resources. Azure returns 200 on RG creation but dependent resources
  # can get ResourceGroupNotFound 404 for ~15-30s due to eventual consistency.
  # See: github.com/hashicorp/terraform-provider-azurerm/issues/4682
  create_duration = "30s"
  depends_on      = [azurerm_resource_group.this]
}

resource "time_sleep" "route_server_delay" {
  # Route Server takes 10-15 min to provision; wait before creating BGP connections.
  create_duration = "60s"

  triggers = {
    route_server_id = azurerm_route_server.this.id
  }
}

# --- Resource Group ---

resource "azurerm_resource_group" "this" {
  count    = var.azure_network_config.create_resource_group ? 1 : 0
  name     = var.azure_network_config.resource_group_name
  location = var.azure_network_config.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.azure_network_config.create_resource_group ? 0 : 1
  name  = var.azure_network_config.resource_group_name
}

locals {
  resource_group_name = var.azure_network_config.resource_group_name
  location            = var.azure_network_config.location
}

# --- Virtual Network ---

resource "azurerm_virtual_network" "this" {
  count               = var.azure_network_config.create_vnet ? 1 : 0
  name                = join("-", ["VNet", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  address_space       = [var.azure_network_config.vnet_cidr]
  tags                = var.tags

  depends_on = [time_sleep.vnet_api_delay]
}

data "azurerm_virtual_network" "existing" {
  count               = var.azure_network_config.create_vnet ? 0 : 1
  name                = split("/", var.azure_network_config.vnet_id)[length(split("/", var.azure_network_config.vnet_id)) - 1]
  resource_group_name = local.resource_group_name
}

locals {
  vnet_name = var.azure_network_config.create_vnet ? azurerm_virtual_network.this[0].name : data.azurerm_virtual_network.existing[0].name
  vnet_id   = var.azure_network_config.create_vnet ? azurerm_virtual_network.this[0].id : data.azurerm_virtual_network.existing[0].id
  vnet_cidr = var.azure_network_config.vnet_cidr
}

# --- Gateway Subnets (WAN + LAN per gateway) ---

resource "azurerm_subnet" "gw_subnets" {
  for_each             = local.gateway_subnets
  name                 = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.deployment_name])
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [each.value.subnet.subnet_cidr]
}

# --- RouteServerSubnet (required name for Azure Route Server) ---

resource "azurerm_subnet" "route_server" {
  name                 = "RouteServerSubnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [local.route_server_subnet_cidr]
}

# --- Network Security Groups ---

resource "azurerm_network_security_group" "public" {
  name                = join("-", ["Public-NSG", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
  depends_on          = [time_sleep.vnet_api_delay]

  security_rule {
    name                       = "Allow-SSH-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-IPsec-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "4500"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "private" {
  name                = join("-", ["Private-NSG", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
  depends_on          = [time_sleep.vnet_api_delay]

  security_rule {
    name                       = "Allow-All-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# --- NSG associations to gateway subnets ---

resource "azurerm_subnet_network_security_group_association" "public" {
  for_each                  = local.gw_public_interfaces
  subnet_id                 = azurerm_subnet.gw_subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  for_each                  = local.gw_lan_interfaces
  subnet_id                 = azurerm_subnet.gw_subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.private.id
}

# --- Route Tables ---
# Public: default route via internet (Azure routes internet traffic automatically
# for subnets with public IPs, but explicit route table mirrors AWS behaviour).

resource "azurerm_route_table" "public" {
  name                          = join("-", ["Public-RT", var.netskope_tenant.deployment_name])
  location                      = local.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = true
  tags                          = var.tags
  depends_on                    = [time_sleep.vnet_api_delay]

  route {
    name           = "Default-Internet"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_route_table" "private" {
  name                          = join("-", ["Private-RT", var.netskope_tenant.deployment_name])
  location                      = local.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = true
  tags                          = var.tags
  depends_on                    = [time_sleep.vnet_api_delay]
}

resource "azurerm_subnet_route_table_association" "public" {
  for_each       = local.gw_public_interfaces
  subnet_id      = azurerm_subnet.gw_subnets[each.key].id
  route_table_id = azurerm_route_table.public.id
}

resource "azurerm_subnet_route_table_association" "private" {
  for_each       = local.gw_lan_interfaces
  subnet_id      = azurerm_subnet.gw_subnets[each.key].id
  route_table_id = azurerm_route_table.private.id
}

# --- Azure Route Server (replaces AWS Transit Gateway + Connect + Connect Peers) ---
#
# Route Server requires:
#   - A dedicated subnet named exactly "RouteServerSubnet" (/27 minimum)
#   - Standard SKU public IP (Zone-redundant)
#   - branch_to_branch_traffic_enabled = true for ECMP across both gateways

resource "azurerm_public_ip" "route_server" {
  name                = join("-", ["RouteServer-PIP", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
  depends_on          = [time_sleep.vnet_api_delay]
}

resource "azurerm_route_server" "this" {
  name                             = join("-", ["RouteServer", var.netskope_tenant.deployment_name])
  location                         = local.location
  resource_group_name              = local.resource_group_name
  sku                              = "Standard"
  public_ip_address_id             = azurerm_public_ip.route_server.id
  subnet_id                        = azurerm_subnet.route_server.id
  branch_to_branch_traffic_enabled = var.azure_route_server.branch_to_branch_traffic
  tags                             = var.tags
}

# BGP connections: one per gateway. The gateway's LAN NIC IP peers with Route Server.
# Route Server ASN is always 65515 (Azure-fixed); gateway ASN = tenant_bgp_asn.

resource "azurerm_route_server_bgp_connection" "gw_peers" {
  for_each        = local.gw_lan_key
  name            = join("-", ["BGP", each.key, var.netskope_tenant.deployment_name])
  route_server_id = azurerm_route_server.this.id
  peer_asn        = tonumber(var.netskope_tenant.tenant_bgp_asn)
  peer_ip         = azurerm_network_interface.gw_interfaces["${each.key}-${each.value}"].private_ip_address

  depends_on = [time_sleep.route_server_delay]
}
