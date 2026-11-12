#------------------------------------------------------------------------------
#  Outputs
#
#  The "Phase 2 inputs" group (virtual_hub_id, virtual_hub_name,
#  virtual_wan_id, resource_group_name, location, virtual_router_ips,
#  virtual_router_asn) are the values consumed by the Netskope NVA spoke
#  Terraform that will be built after this deployment.
#------------------------------------------------------------------------------

#-- Lab context ---------------------------------------------------------------

output "resource_group_name" {
  value       = azurerm_resource_group.lab.name
  description = "Name of the lab resource group."
}

output "location" {
  value       = azurerm_resource_group.lab.location
  description = "Azure region for the lab."
}

#-- Virtual WAN / Hub ---------------------------------------------------------

output "virtual_wan_id" {
  value       = azurerm_virtual_wan.lab.id
  description = "Resource ID of the Virtual WAN."
}

output "virtual_hub_id" {
  value       = azurerm_virtual_hub.lab.id
  description = "Resource ID of the virtual hub. Used by Phase 2 NVA spoke hub connection and BGP connection."
}

output "virtual_hub_name" {
  value       = azurerm_virtual_hub.lab.name
  description = "Name of the virtual hub."
}

output "virtual_router_ips" {
  value       = azurerm_virtual_hub.lab.virtual_router_ips
  description = "IP addresses of the hub's built-in BGP router (two IPs for HA). Phase 2 NVA peers to both of these."
}

output "virtual_router_asn" {
  value       = azurerm_virtual_hub.lab.virtual_router_asn
  description = "BGP ASN of the hub's built-in router (always 65515 for Azure Virtual WAN)."
}

#-- Spoke VNets ---------------------------------------------------------------

output "spoke_vnet_ids" {
  value = {
    for k, v in azurerm_virtual_network.spoke : k => v.id
  }
  description = "Resource IDs of the spoke VNets."
}

output "spoke_vnet_address_spaces" {
  value = {
    for k, v in azurerm_virtual_network.spoke : k => v.address_space
  }
  description = "Address spaces of the spoke VNets."
}

output "spoke_subnet_ids" {
  value = {
    for k, v in azurerm_subnet.spoke_vm : k => v.id
  }
  description = "Resource IDs of the VM subnets (snet-vm) in each spoke."
}

output "hub_connection_ids" {
  value = {
    for k, v in azurerm_virtual_hub_connection.spoke : k => v.id
  }
  description = "Resource IDs of the hub-to-spoke connections."
}

#-- Test VMs ------------------------------------------------------------------

output "vm_private_ips" {
  value = {
    for k, v in azurerm_network_interface.spoke : k => v.private_ip_address
  }
  description = "Private IP addresses of the test VMs."
}

output "vm_public_ips" {
  value = {
    for k, v in azurerm_public_ip.spoke : k => v.ip_address
  }
  description = "Public IP addresses of the test VMs. SSH target for acceptance testing."
}