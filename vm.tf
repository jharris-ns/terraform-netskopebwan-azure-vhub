#------------------------------------------------------------------------------
#  Azure Virtual Machines — Netskope BWAN Gateways
#
#  Each VM uses the Netskope BWAN Marketplace image, cloud-init to inject
#  the activation token and tenant URL, and dual NICs (WAN primary, LAN secondary).
#
#  The Azure VM Agent is pre-installed in Azure Marketplace images.
#  No separate agent installation is needed (unlike AWS which installs SSM agent).
#
#  Marketplace image (confirmed):
#    Publisher: netskopebwan
#    Offer:     netskope-unified-sase-virtual-gateway
#    SKU/Plan:  netskope-unified-sase-virtual-gateway-r6_2_x
#    Version:   6.2.5
#
#  IMPORTANT: Before first deploy, accept the Marketplace image terms:
#    az vm image terms accept \
#      --publisher netskopebwan \
#      --offer netskope-unified-sase-virtual-gateway \
#      --plan netskope-unified-sase-virtual-gateway-r6_2_x
#  Or set var.azure_vm_config.accept_plan = true to have Terraform do it.
#------------------------------------------------------------------------------

# --- Marketplace Agreement (accept terms if required) ---

resource "azurerm_marketplace_agreement" "netskope_bwan" {
  count     = var.azure_vm_config.accept_plan ? 1 : 0
  publisher = var.azure_vm_config.image_publisher
  offer     = var.azure_vm_config.image_offer
  plan      = var.azure_vm_config.image_sku
}

# --- Gateway VMs ---

resource "azurerm_linux_virtual_machine" "gateways" {
  for_each            = local.gateways
  name                = join("-", [each.key, var.netskope_tenant.deployment_name])
  location            = local.location
  resource_group_name = local.resource_group_name
  size                = var.azure_vm_config.vm_size
  zone                = each.value.availability_zone
  tags                = var.tags

  # WAN NIC must be first (index 0) so the default route points internet-ward.
  # Azure assigns the default gateway based on the primary NIC (first in the list).
  network_interface_ids = [
    azurerm_network_interface.gw_interfaces["${each.key}-ge1"].id,
    azurerm_network_interface.gw_interfaces["${each.key}-ge2"].id,
  ]

  # Cloud-init equivalent of AWS user-data.
  # Sets gateway admin password, tenant URL, and activation token.
  # The Azure VM Agent is pre-installed — no SSM agent installation needed.
  custom_data = base64encode(templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.netskope_gateway_config.gateway_password
    netskope_tenant_url          = local.tenant_url
    netskope_gw_activation_key   = netskopebwan_gateway_activate.gateways[each.key].token
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = var.azure_vm_config.image_publisher
    offer     = var.azure_vm_config.image_offer
    sku       = var.azure_vm_config.image_sku
    version   = var.azure_vm_config.image_version
  }

  # Required for all Marketplace images regardless of whether terms were pre-accepted.
  # accept_plan controls the azurerm_marketplace_agreement resource (accepting terms),
  # but the plan block itself is always required by Azure for Marketplace VMs.
  plan {
    name      = var.azure_vm_config.image_sku
    publisher = var.azure_vm_config.image_publisher
    product   = var.azure_vm_config.image_offer
  }

  admin_username = var.azure_vm_config.admin_username
  # admin_password is required when ssh_public_key is empty (disable_password_authentication = false).
  # Azure complexity rules: 12-123 chars, must contain 3 of: uppercase, lowercase, digit, special.
  admin_password = var.azure_vm_config.ssh_public_key == "" ? var.azure_vm_config.admin_password : null

  # Use SSH key if provided, otherwise fall back to password auth.
  # Netskope BWAN images may require password-based admin access for gateway config.
  dynamic "admin_ssh_key" {
    for_each = var.azure_vm_config.ssh_public_key != "" ? [1] : []
    content {
      username   = var.azure_vm_config.admin_username
      public_key = var.azure_vm_config.ssh_public_key
    }
  }

  disable_password_authentication = var.azure_vm_config.ssh_public_key != "" ? true : false

  # Boot diagnostics — uses managed storage (no storage account needed)
  boot_diagnostics {}

  depends_on = [azurerm_marketplace_agreement.netskope_bwan]

  lifecycle {
    # Ignore custom_data changes after initial deploy (token changes would recreate VM).
    ignore_changes = [custom_data]
  }
}
