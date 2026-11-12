#------------------------------------------------------------------------------
#  Terraform and Provider Version Constraints
#------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.3"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    netskopebwan = {
      source  = "netskopeoss/netskopebwan"
      version = "0.0.2"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.7"
    }
  }
}
