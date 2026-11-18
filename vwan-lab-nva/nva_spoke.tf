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
# No static_vnet_route: 0.0.0.0/0 is advertised to the vhub via eBGP from each
# gateway (azurerm_virtual_hub_bgp_connection). The hub learns it as
# HubBgpConnection routes and programs it into spoke VM NICs via
# internet_security_enabled=true on the spoke connections. This gives true ECMP
# across all gateways — a static_vnet_route can only specify a single next hop.
resource "azurerm_virtual_hub_connection" "nva_spoke" {
  name                      = "conn-nva-spoke"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.nva_spoke.id
  internet_security_enabled = false
}

# Allow the hub connection to fully provision before creating BGP connections.
# Azure returns success on hub connection creation before routing is fully active.
resource "time_sleep" "hub_connection_delay" {
  create_duration = "60s"
  triggers = {
    hub_connection_id = azurerm_virtual_hub_connection.nva_spoke.id
  }
}

# Remove the static 0.0.0.0/0 route that the azurerm provider re-injects on
# every apply. The route is undesirable because it hardcodes a single gateway
# as next hop, defeating ECMP. 0.0.0.0/0 is correctly learned from all
# gateways via HubBgpConnection — no static override needed.
#
# This null_resource runs after every hub connection change and after the
# connection delay, ensuring the static route is always absent post-apply.
resource "null_resource" "remove_static_default_route" {
  triggers = {
    hub_connection_id = azurerm_virtual_hub_connection.nva_spoke.id
    # Re-run whenever gateway count changes so new applies are always clean.
    gateway_count = var.gateway_count
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Removing static 0.0.0.0/0 route from conn-nva-spoke (azurerm provider limitation)..."
      az network vhub connection update \
        --resource-group ${var.resource_group_name} \
        --vhub-name $(basename ${var.virtual_hub_id}) \
        --name conn-nva-spoke \
        --remove routingConfiguration.vnetRoutes.staticRoutes \
        --output none 2>&1 || true
      echo "Done."
    EOT
  }

  depends_on = [time_sleep.hub_connection_delay]
}
