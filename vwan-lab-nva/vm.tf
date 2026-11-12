#------------------------------------------------------------------------------
#  NVA VMs — Netskope BWAN Marketplace image
#
#  Image: netskopebwan / netskope-unified-sase-virtual-gateway /
#         netskope-unified-sase-virtual-gateway-r6_2_x / 6.2.5
#  Generation: 1 only — do not use Gen2-only VM sizes.
#
#  Before first deploy, accept Marketplace terms (or set accept_plan = true):
#    az vm image terms accept \
#      --publisher netskopebwan \
#      --offer netskope-unified-sase-virtual-gateway \
#      --plan netskope-unified-sase-virtual-gateway-r6_2_x
#
#  The plan {} block is always required for Marketplace VMs in azurerm,
#  regardless of whether accept_plan = true.
#
#  VM names: "vm-{gateway_prefix}-{n}" e.g. "vm-ntsk-gw-1"
#------------------------------------------------------------------------------

resource "azurerm_marketplace_agreement" "netskope_bwan" {
  count     = var.accept_plan ? 1 : 0
  publisher = "netskopebwan"
  offer     = "netskope-unified-sase-virtual-gateway"
  plan      = "netskope-unified-sase-virtual-gateway-r6_2_x"
}

resource "azurerm_linux_virtual_machine" "nva" {
  for_each                        = local.nvas
  name                            = "vm-${each.key}"
  resource_group_name             = local.resource_group_name
  location                        = local.location
  size                            = var.vm_size
  admin_username                  = "netskope"
  admin_password                  = var.admin_password
  disable_password_authentication = false

  # GE1 (WAN) must be first — Azure assigns the default gateway based on the primary NIC.
  network_interface_ids = [
    azurerm_network_interface.nva_ge1["${each.key}-ge1"].id,
    azurerm_network_interface.nva_ge2["${each.key}-ge2"].id,
  ]

  # Cloud-init: sets gateway password, tenant URL, and activation token.
  # custom_data changes are ignored after initial deploy (token changes would recreate the VM).
  custom_data = base64encode(templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.gateway_password
    netskope_tenant_url          = local.tenant_url
    netskope_gw_activation_key   = netskopebwan_gateway_activate.nva[each.key].token
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "netskopebwan"
    offer     = "netskope-unified-sase-virtual-gateway"
    sku       = "netskope-unified-sase-virtual-gateway-r6_2_x"
    version   = "6.2.5"
  }

  # Required for all Marketplace VMs — Azure validates this regardless of accept_plan.
  plan {
    name      = "netskope-unified-sase-virtual-gateway-r6_2_x"
    publisher = "netskopebwan"
    product   = "netskope-unified-sase-virtual-gateway"
  }

  boot_diagnostics {}

  depends_on = [azurerm_marketplace_agreement.netskope_bwan]

  lifecycle {
    ignore_changes = [custom_data]
  }
}
