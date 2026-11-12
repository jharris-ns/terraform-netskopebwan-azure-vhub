#------------------------------------------------------------------------------
#  Computed locals
#
#  Mirrors the AWS project pattern: gateway_count drives a `nvas` map keyed by
#  "{gateway_prefix}-{n}". Subnet CIDRs are auto-carved from nva_spoke_address_space
#  using the same cidrsubnet formula as the AWS project.
#
#  With nva_spoke_address_space="10.3.0.0/24", subnet_size=28, gateway_count=2:
#    ntsk-gw-1  GE1: 10.3.0.0/28   GE2: 10.3.0.16/28
#    ntsk-gw-2  GE1: 10.3.0.32/28  GE2: 10.3.0.48/28
#------------------------------------------------------------------------------

locals {
  resource_group_name = var.resource_group_name
  location            = var.location

  # vhub BGP peer IPs — sorted for stable ordering (Terraform set iteration is non-deterministic)
  vhub_peer_ips = sort(tolist(var.virtual_router_ips))

  # Prefix length of the spoke VNet CIDR (e.g. 24 for "10.3.0.0/24")
  spoke_prefix_len = tonumber(split("/", var.nva_spoke_address_space)[1])

  #----------------------------------------------------------------------------
  # Per-gateway map
  # Key:   "{gateway_prefix}-{n}"  e.g. "ntsk-gw-1"
  # Value: ge1/ge2 subnet CIDRs and their first usable IP (Azure gateway)
  #----------------------------------------------------------------------------
  nvas = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {
      ge1_subnet  = cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2)
      ge2_subnet  = cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2 + 1)
      ge1_gateway = cidrhost(cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2), 1)
      ge2_gateway = cidrhost(cidrsubnet(var.nva_spoke_address_space, var.subnet_size - local.spoke_prefix_len, i * 2 + 1), 1)
    }
  }

  #----------------------------------------------------------------------------
  # Flat interface map — keyed by "{gw_key}-ge1" / "{gw_key}-ge2"
  # Used for: subnets, NICs, public IPs, NSG associations (all need for_each
  # over individual interfaces rather than gateways).
  #----------------------------------------------------------------------------
  nva_interfaces = merge([
    for gw_key, gw in local.nvas : {
      "${gw_key}-ge1" = {
        gw_key  = gw_key
        intf    = "ge1"
        subnet  = gw.ge1_subnet
        gateway = gw.ge1_gateway
        public  = true
      }
      "${gw_key}-ge2" = {
        gw_key  = gw_key
        intf    = "ge2"
        subnet  = gw.ge2_subnet
        gateway = gw.ge2_gateway
        public  = false
      }
    }
  ]...)

  # Subset maps for NSG routing (public = GE1/WAN, private = GE2/LAN)
  nva_public_interfaces  = { for k, v in local.nva_interfaces : k => v if v.public }
  nva_private_interfaces = { for k, v in local.nva_interfaces : k => v if !v.public }

  #----------------------------------------------------------------------------
  # BGP peer flat map — two peers per gateway (vhub HA router IPs)
  # Keyed by "{gw_key}-peer1" / "{gw_key}-peer2"
  #----------------------------------------------------------------------------
  nva_bgp_peers = merge([
    for gw_key in keys(local.nvas) : {
      "${gw_key}-peer1" = { gw_key = gw_key, neighbor = local.vhub_peer_ips[0] }
      "${gw_key}-peer2" = { gw_key = gw_key, neighbor = local.vhub_peer_ips[1] }
    }
  ]...)
}
