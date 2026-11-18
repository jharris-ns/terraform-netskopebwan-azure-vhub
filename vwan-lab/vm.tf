#------------------------------------------------------------------------------
#  Test VMs — one per spoke
#
#  No public IPs — test VMs are reached via az vm run-command (Azure control
#  plane, no inbound internet access required). Internet traffic routes through
#  the vhub to the Netskope NVA gateways.
#
#  Image: Ubuntu 22.04 LTS Gen2 (Canonical)
#  Size:  Standard_B2s — Gen1/Gen2 compatible, sufficient for a connectivity test.
#         Check zone availability before changing size:
#           az vm list-skus --location <region> --size Standard_B2s --zone true -o table
#------------------------------------------------------------------------------

resource "azurerm_network_interface" "spoke" {
  for_each = local.spokes

  name                = each.value.nic_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.spoke_vm[each.key].id
    private_ip_address_allocation = "Dynamic"
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