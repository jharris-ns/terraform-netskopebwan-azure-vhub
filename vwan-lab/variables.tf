#------------------------------------------------------------------------------
#  Input Variables
#------------------------------------------------------------------------------

variable "location" {
  type        = string
  description = "Azure region for all resources."
  default     = "eastus"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group for the lab."
  default     = "rg-vwan-lab"
}

variable "vwan_name" {
  type        = string
  description = "Name of the Virtual WAN resource."
  default     = "vwan-lab-01"
}

variable "vhub_name" {
  type        = string
  description = "Name of the virtual hub."
  default     = "vhub-lab-eastus-01"
}

variable "vhub_address_prefix" {
  type        = string
  description = "Address prefix for the virtual hub (/24 minimum). Must not overlap with spoke VNets."
  default     = "10.0.0.0/24"
}

variable "spoke1_address_space" {
  type        = string
  description = "Address space for spoke 1 VNet."
  default     = "10.1.0.0/24"
}

variable "spoke1_subnet_prefix" {
  type        = string
  description = "CIDR for spoke 1 VM subnet."
  default     = "10.1.0.0/26"
}

variable "spoke2_address_space" {
  type        = string
  description = "Address space for spoke 2 VNet."
  default     = "10.2.0.0/24"
}

variable "spoke2_subnet_prefix" {
  type        = string
  description = "CIDR for spoke 2 VM subnet."
  default     = "10.2.0.0/26"
}

variable "vm_size" {
  type        = string
  description = "VM size for the test VMs."
  default     = "Standard_B2s"
}

variable "admin_username" {
  type        = string
  description = "Admin username for test VMs."
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key file used for VM admin authentication."
}

variable "ssh_source_address" {
  type        = string
  description = "Source IP/CIDR permitted to SSH to the test VMs. Restrict to your management IP in production."
  default     = "*"
}