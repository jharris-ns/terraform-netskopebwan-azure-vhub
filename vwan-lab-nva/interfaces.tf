#------------------------------------------------------------------------------
#  NICs and Public IPs
#
#  GE1 (WAN): public IP + NIC — primary interface, determines Azure default route.
#  GE2 (LAN): NIC with ip_forwarding_enabled — BGP source IP for vhub peering.
#
#  All resources use for_each over local.nva_public_interfaces (GE1) or
#  local.nva_private_interfaces (GE2). Keys: "{gw_key}-ge1" / "{gw_key}-ge2".
#
#  GE1 must be first in the VM's network_interface_ids list so Azure sets the
#  default gateway to the GE1 subnet gateway (internet-ward). See vm.tf.
#------------------------------------------------------------------------------

# Public IPs — one per WAN (GE1) interface
resource "azurerm_public_ip" "nva_ge1" {
  for_each            = local.nva_public_interfaces
  name                = "pip-ge1-${each.value.gw_key}"
  resource_group_name = local.resource_group_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

# GE1 NICs — WAN, one per gateway
resource "azurerm_network_interface" "nva_ge1" {
  for_each            = local.nva_public_interfaces
  name                = "nic-ge1-${each.value.gw_key}"
  resource_group_name = local.resource_group_name
  location            = local.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.nva[each.key].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.nva_ge1[each.key].id
  }
}

# GE2 NICs — LAN, ip_forwarding for routed traffic; BGP peer IP for vhub connection
resource "azurerm_network_interface" "nva_ge2" {
  for_each              = local.nva_private_interfaces
  name                  = "nic-ge2-${each.value.gw_key}"
  resource_group_name   = local.resource_group_name
  location              = local.location
  ip_forwarding_enabled = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.nva[each.key].id
    private_ip_address_allocation = "Dynamic"
  }
}

# NIC-level NSG associations (belt-and-suspenders with subnet associations in nsg.tf)
resource "azurerm_network_interface_security_group_association" "ge1" {
  for_each                  = local.nva_public_interfaces
  network_interface_id      = azurerm_network_interface.nva_ge1[each.key].id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_network_interface_security_group_association" "ge2" {
  for_each                  = local.nva_private_interfaces
  network_interface_id      = azurerm_network_interface.nva_ge2[each.key].id
  network_security_group_id = azurerm_network_security_group.private.id
}
