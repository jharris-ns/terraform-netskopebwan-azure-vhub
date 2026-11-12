#------------------------------------------------------------------------------
#  NVA Spoke VNet, Subnets, and Hub Connection
#
#  Single VNet and hub connection shared across all NVA gateways.
#  Subnets are created per-interface (GE1 + GE2 per gateway) via for_each
#  over local.nva_interfaces.
#------------------------------------------------------------------------------

resource "azurerm_virtual_network" "nva_spoke" {
  name                = "vnet-nva-${var.location}-01"
  resource_group_name = local.resource_group_name
  location            = local.location
  address_space       = [var.nva_spoke_address_space]
}

# One subnet per interface (GE1 and GE2) per gateway
resource "azurerm_subnet" "nva" {
  for_each             = local.nva_interfaces
  name                 = "snet-${each.value.intf}-${each.value.gw_key}"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.nva_spoke.name
  address_prefixes     = [each.value.subnet]
}

# Hub connection — attaches the NVA spoke to the Phase 1 vhub.
#
# routing.static_vnet_route injects a static 0.0.0.0/0 into the hub's default
# route table pointing to the NVA's LAN (GE2) IP. The hub propagates this to all
# other spoke connections, so spoke VMs send internet traffic through the NVA.
# This is the spoke-based NVA equivalent of Routing Intent (which requires a
# hub-hosted managed NVA resource and is not applicable here).
#
# With multiple gateways the first NVA's LAN IP is used as the static next hop.
# Azure vWAN will ECMP across the BGP-learned routes from all NVA peers, but the
# static_vnet_route only accepts a single next_hop_ip_address.
resource "azurerm_virtual_hub_connection" "nva_spoke" {
  name                      = "conn-nva-spoke"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.nva_spoke.id
  internet_security_enabled = false

  routing {
    static_vnet_route {
      name                = "default-via-nva"
      address_prefixes    = ["0.0.0.0/0"]
      next_hop_ip_address = azurerm_network_interface.nva_ge2["${keys(local.nvas)[0]}-ge2"].private_ip_address
    }
  }
}

# Allow the hub connection to fully provision before creating BGP connections.
# Azure returns success on hub connection creation before routing is fully active.
resource "time_sleep" "hub_connection_delay" {
  create_duration = "60s"
  triggers = {
    hub_connection_id = azurerm_virtual_hub_connection.nva_spoke.id
  }
}
