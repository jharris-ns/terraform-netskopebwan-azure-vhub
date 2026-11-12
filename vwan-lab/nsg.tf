#------------------------------------------------------------------------------
#  NSGs and Subnet Associations
#
#  Rules per spoke:
#    100 — Allow inbound SSH from var.ssh_source_address (your management IP)
#    110 — Allow inbound ICMP from the VirtualNetwork service tag
#          (covers both spokes once they share the same hub; required for AC3 ping test)
#
#  All other inbound traffic is denied by the default Azure DenyAllInBound rule.
#  Outbound is unrestricted (default Azure AllowAllOutBound).
#------------------------------------------------------------------------------

resource "azurerm_network_security_group" "spoke" {
  for_each = local.spokes

  name                = each.value.nsg_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  security_rule {
    name                       = "allow-ssh-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_source_address
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-icmp-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "spoke" {
  for_each = local.spokes

  subnet_id                 = azurerm_subnet.spoke_vm[each.key].id
  network_security_group_id = azurerm_network_security_group.spoke[each.key].id
}