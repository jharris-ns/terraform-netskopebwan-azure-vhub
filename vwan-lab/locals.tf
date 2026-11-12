#------------------------------------------------------------------------------
#  Spoke definitions
#
#  Centralises all per-spoke values so that vnet/subnet/nsg/vm resources can
#  all use for_each over this map. Adding a third spoke (e.g. for the NVA
#  phase) means extending this map and re-applying.
#------------------------------------------------------------------------------

locals {
  spokes = {
    spoke1 = {
      index         = 1
      vnet_name     = "vnet-spoke1-${var.location}-01"
      address_space = var.spoke1_address_space
      subnet_prefix = var.spoke1_subnet_prefix
      nsg_name      = "nsg-spoke1-vm"
      vm_name       = "vm-spoke1-test01"
      pip_name      = "pip-vm-spoke1-test01"
      nic_name      = "nic-vm-spoke1-test01"
    }
    spoke2 = {
      index         = 2
      vnet_name     = "vnet-spoke2-${var.location}-01"
      address_space = var.spoke2_address_space
      subnet_prefix = var.spoke2_subnet_prefix
      nsg_name      = "nsg-spoke2-vm"
      vm_name       = "vm-spoke2-test01"
      pip_name      = "pip-vm-spoke2-test01"
      nic_name      = "nic-vm-spoke2-test01"
    }
  }
}