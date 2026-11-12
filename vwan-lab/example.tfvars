#------------------------------------------------------------------------------
#  Example variable values — safe to commit, no secrets.
#  Copy to terraform.tfvars and fill in ssh_source_address and
#  ssh_public_key_path for your environment.
#------------------------------------------------------------------------------

location            = "eastus"
resource_group_name = "rg-vwan-lab"

vwan_name           = "vwan-lab-01"
vhub_name           = "vhub-lab-eastus-01"
vhub_address_prefix = "10.0.0.0/24"

spoke1_address_space = "10.1.0.0/24"
spoke1_subnet_prefix = "10.1.0.0/26"

spoke2_address_space = "10.2.0.0/24"
spoke2_subnet_prefix = "10.2.0.0/26"

vm_size        = "Standard_B2s"
admin_username = "azureuser"

# Path to your SSH public key
ssh_public_key_path = "~/.ssh/id_rsa.pub"

# Restrict to your management IP to limit exposure (e.g. "1.2.3.4/32")
ssh_source_address = "*"