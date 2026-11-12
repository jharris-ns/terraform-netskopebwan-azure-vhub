#------------------------------------------------------------------------------
#  NICs and Public IPs (per gateway x interface)
#
#  Each gateway has:
#    ge1 — WAN NIC with static Public IP (Standard SKU, zonal)
#    ge2 — LAN NIC with IP forwarding enabled (for routing)
#
#  In Azure, the primary NIC (index 0 in VM) determines the default route.
#  WAN NIC (ge1) is set as primary so the default gateway points internet-ward.
#  LAN NIC (ge2) has IP forwarding enabled so the VM can route transited traffic.
#------------------------------------------------------------------------------

# --- Static Public IPs (WAN interfaces only) ---
# Zone-redundant (all 3 zones) so the VM can be placed in whichever zone has capacity.

resource "azurerm_public_ip" "gw_eips" {
  for_each            = local.gw_public_interfaces
  name                = join("-", [each.value.gw_key, upper(each.value.intf_key), "PIP", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
  depends_on          = [time_sleep.vnet_api_delay]
}

# --- NICs (WAN + LAN per gateway) ---

resource "azurerm_network_interface" "gw_interfaces" {
  for_each            = local.gateway_subnets
  name                = join("-", [each.value.gw_key, upper(each.value.intf_key), "NIC", var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  # LAN NIC must forward packets between the gateway container and Azure subnets.
  ip_forwarding_enabled = each.value.subnet.overlay == null ? true : false
  tags                 = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.gw_subnets[each.key].id
    private_ip_address_allocation = "Dynamic"
    # Attach public IP to WAN (ge1) interfaces only
    public_ip_address_id = each.value.subnet.overlay == "public" ? azurerm_public_ip.gw_eips[each.key].id : null
  }
}

# --- NSG associations at NIC level ---
# NSG is also associated at subnet level, but NIC-level associations are kept for
# explicit per-interface control (mirrors AWS ENI security group attachment).

resource "azurerm_network_interface_security_group_association" "public" {
  for_each                  = local.gw_public_interfaces
  network_interface_id      = azurerm_network_interface.gw_interfaces[each.key].id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_network_interface_security_group_association" "private" {
  for_each                  = local.gw_lan_interfaces
  network_interface_id      = azurerm_network_interface.gw_interfaces[each.key].id
  network_security_group_id = azurerm_network_security_group.private.id
}
