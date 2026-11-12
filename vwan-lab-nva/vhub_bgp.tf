#------------------------------------------------------------------------------
#  Azure vhub BGP Connections
#
#  One BGP connection per NVA gateway — registers each NVA's GE2 (LAN) IP
#  as a BGP peer with the vhub built-in router.
#
#  All connections reference the same hub VNet connection (virtual_network_connection_id).
#  The vhub router initiates BGP sessions to each peer_ip (NVA GE2).
#
#  Verify after apply:
#    az network vhub bgpconnection list \
#      --resource-group rg-ntsk-gw \
#      --vhub-name vhub-ntsk-gw-westeurope-01 -o table
#------------------------------------------------------------------------------

resource "azurerm_virtual_hub_bgp_connection" "nva" {
  for_each       = local.nvas
  name           = "bgp-conn-${each.key}"
  virtual_hub_id = var.virtual_hub_id
  peer_asn       = var.gateway_bgp_asn
  peer_ip        = azurerm_network_interface.nva_ge2["${each.key}-ge2"].private_ip_address

  # Required: tells Azure which hub VNet connection this BGP peer belongs to.
  virtual_network_connection_id = azurerm_virtual_hub_connection.nva_spoke.id

  depends_on = [time_sleep.hub_connection_delay]
}
