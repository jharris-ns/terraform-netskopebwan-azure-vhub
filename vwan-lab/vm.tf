#------------------------------------------------------------------------------
#  Test VMs — one per spoke
#
#  Public IPs are included so that the test VMs are reachable for SSH without
#  a Bastion or jumpbox. Restrict var.ssh_source_address in the NSG to limit
#  exposure.
#
#  Image: Ubuntu 22.04 LTS Gen2 (Canonical)
#  Size:  Standard_B2s — Gen1/Gen2 compatible, sufficient for a connectivity test.
#         Check zone availability before changing size:
#           az vm list-skus --location <region> --size Standard_B2s --zone true -o table
#------------------------------------------------------------------------------

resource "azurerm_public_ip" "spoke" {
  for_each = local.spokes

  name                = each.value.pip_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "spoke" {
  for_each = local.spokes

  name                = each.value.nic_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke_vm[each.key].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.spoke[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "spoke" {
  for_each = local.spokes

  name                  = each.value.vm_name
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.spoke[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}