#------------------------------------------------------------------------------
#  Outputs
#------------------------------------------------------------------------------

output "gateways" {
  description = "Deployed gateway VMs and their BGP config status"
  value = {
    for gw_key, gw in local.gateways : gw_key => {
      vm_name              = azurerm_linux_virtual_machine.gateways[gw_key].name
      wan_public_ip        = azurerm_public_ip.gw_eips["${gw_key}-ge1"].ip_address
      lan_private_ip       = azurerm_network_interface.gw_interfaces["${gw_key}-ge2"].private_ip_address
      availability_zone    = gw.availability_zone
      bgp_config_applied   = try(null_resource.gre_config[gw_key].id != null, false)
      sse_monitor_deployed = try(null_resource.sse_monitor[gw_key].id != null, false)
    }
  }
}

output "route_server_peer_ips" {
  description = "Azure Route Server BGP peer IPs (Route Server ASN is always 65515)"
  value       = azurerm_route_server.this.virtual_router_ips
}

output "route_server_id" {
  description = "Azure Route Server resource ID"
  value       = azurerm_route_server.this.id
}

output "computed_gateway_map" {
  description = "Auto-computed gateway configuration from gateway_count"
  value       = local.gateways
}

output "resource_group_name" {
  description = "Resource group containing all deployed resources"
  value       = local.resource_group_name
}

output "vnet_id" {
  description = "VNet resource ID"
  value       = local.vnet_id
}
