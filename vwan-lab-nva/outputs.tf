#------------------------------------------------------------------------------
#  Outputs
#------------------------------------------------------------------------------

output "nva_vm_names" {
  value       = { for k, v in azurerm_linux_virtual_machine.nva : k => v.name }
  description = "Map of gateway key → VM name."
}

output "nva_ge1_public_ips" {
  value       = { for k, v in azurerm_public_ip.nva_ge1 : k => v.ip_address }
  description = "Map of interface key → public IP of the GE1 (WAN) interface."
}

output "nva_ge2_private_ips" {
  value       = { for k, v in azurerm_network_interface.nva_ge2 : k => v.private_ip_address }
  description = "Map of interface key → private IP of the GE2 (LAN) interface (BGP peer IP)."
}

output "nva_spoke_vnet_id" {
  value       = azurerm_virtual_network.nva_spoke.id
  description = "Resource ID of the NVA spoke VNet."
}

output "hub_connection_id" {
  value       = azurerm_virtual_hub_connection.nva_spoke.id
  description = "Resource ID of the NVA spoke hub connection."
}

output "vhub_bgp_connection_ids" {
  value       = { for k, v in azurerm_virtual_hub_bgp_connection.nva : k => v.id }
  description = "Map of gateway key → vhub BGP connection resource ID."
}

output "bgp_verify_commands" {
  value = merge(
    { for k, v in azurerm_linux_virtual_machine.nva :
      "bgp_summary_${k}" => "az vm run-command invoke --resource-group ${local.resource_group_name} --name ${v.name} --command-id RunShellScript --scripts \"docker exec infiot_spoke vtysh -c 'show bgp summary'\""
    },
    {
      effective_routes = "az network vhub get-effective-routes --resource-group ${local.resource_group_name} --name ${split("/", var.virtual_hub_id)[8]} --resource-type HubVirtualNetworkConnection --resource-id ${azurerm_virtual_hub_connection.nva_spoke.id} -o table"
      list_bgp_conns   = "az network vhub bgpconnection list --resource-group ${local.resource_group_name} --vhub-name ${split("/", var.virtual_hub_id)[8]} -o table"
    }
  )
  description = "Ready-to-run commands to verify BGP state after apply."
}
