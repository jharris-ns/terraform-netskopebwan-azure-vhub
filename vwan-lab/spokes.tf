#------------------------------------------------------------------------------
#  Spoke VNets, Subnets, and Hub Connections
#
#  internet_security_enabled = true — forces spoke VMs to route internet traffic
#  via the vhub. The vhub pushes any 0.0.0.0/0 it has learned (via BGP from the
#  NVA gateway) into the spoke VM NICs as a VirtualNetworkGateway route,
#  overriding the default Azure internet route. Transitive spoke-to-spoke routing
#  is provided by the hub router automatically once both connections are attached.
#------------------------------------------------------------------------------

resource "azurerm_virtual_network" "spoke" {
  for_each = local.spokes

  name                = each.value.vnet_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [each.value.address_space]
}

resource "azurerm_subnet" "spoke_vm" {
  for_each = local.spokes

  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.spoke[each.key].name
  address_prefixes     = [each.value.subnet_prefix]
}

resource "azurerm_virtual_hub_connection" "spoke" {
  for_each = local.spokes

  name                      = "conn-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.lab.id
  remote_virtual_network_id = azurerm_virtual_network.spoke[each.key].id
  internet_security_enabled = true
}