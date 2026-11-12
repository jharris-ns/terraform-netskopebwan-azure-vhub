#------------------------------------------------------------------------------
#  Resource Group, Virtual WAN, and Virtual Hub
#
#  Virtual Hub provisioning takes 15–30 minutes. Do not cancel a running apply
#  during hub creation; check Azure portal for provisioningState if it appears
#  to stall, then re-run `terraform apply` to continue.
#
#  Type = "Standard" is required even at this phase. Basic cannot be upgraded
#  in-place, and Phase 2 (NVA BGP peering via azurerm_virtual_hub_bgp_connection)
#  requires a Standard hub.
#------------------------------------------------------------------------------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_wan" "lab" {
  name                          = var.vwan_name
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  type                          = "Standard"
  allow_branch_to_branch_traffic = true
}

resource "azurerm_virtual_hub" "lab" {
  name                = var.vhub_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  virtual_wan_id      = azurerm_virtual_wan.lab.id
  address_prefix      = var.vhub_address_prefix

  # sku is inherited from the Virtual WAN type (Standard)
}