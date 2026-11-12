#------------------------------------------------------------------------------
#  Network Security Groups
#
#  public (GE1/WAN):  Allow SSH + UDP 4500 IPsec inbound.
#  private (GE2/LAN): Allow all — LAN is an internal network, BGP traffic from
#                     the vhub router arrives here.
#
#  NSGs are associated at both subnet and NIC level (belt-and-suspenders).
#  for_each over nva_public/private_interfaces handles all gateways.
#------------------------------------------------------------------------------

resource "azurerm_network_security_group" "public" {
  name                = "nsg-nva-public"
  resource_group_name = local.resource_group_name
  location            = local.location

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
  name                = "nsg-nva-private"
  resource_group_name = local.resource_group_name
  location            = local.location

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

# Subnet-level NSG associations
resource "azurerm_subnet_network_security_group_association" "ge1" {
  for_each                  = local.nva_public_interfaces
  subnet_id                 = azurerm_subnet.nva[each.key].id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "ge2" {
  for_each                  = local.nva_private_interfaces
  subnet_id                 = azurerm_subnet.nva[each.key].id
  network_security_group_id = azurerm_network_security_group.private.id
}
