#------------------------------------------------------------------------------
#  Auto-computed gateway map from gateway_count
#
#  Subnets are carved from vnet_cidr using cidrsubnet():
#    ge1 (WAN/public)  — even indices: 0, 2, 4, ...
#    ge2 (LAN/private) — odd  indices: 1, 3, 5, ...
#
#  Azure availability zones are integers 1, 2, 3 (not AZ names like AWS).
#  Standard_D8ds_v4 confirmed available in Zone 1 in eastus.
#
#  RouteServerSubnet (/27) is auto-computed after the gateway subnets.
#  This formula assumes subnet_size = 28 (each /27 holds 2 gateway /28s).
#  Override via var.azure_route_server.route_server_subnet_cidr if needed.
#------------------------------------------------------------------------------

locals {
  vnet_prefix_len = tonumber(split("/", var.azure_network_config.vnet_cidr)[1])

  gateways = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {
      availability_zone = "1" # Standard_D8ds_v4 confirmed available in Zone 1 (eastus); both gateways placed here
      subnets = {
        ge1 = {
          subnet_cidr = cidrsubnet(var.azure_network_config.vnet_cidr, var.subnet_size - local.vnet_prefix_len, i * 2)
          overlay     = "public"
        }
        ge2 = {
          subnet_cidr = cidrsubnet(var.azure_network_config.vnet_cidr, var.subnet_size - local.vnet_prefix_len, i * 2 + 1)
          overlay     = null
        }
      }
      bgp_metric   = "10"
      gateway_name = "${var.gateway_prefix}-${i + 1}"
      gateway_role = var.gateway_role
    }
  }

  # Flatten gateways x interfaces for per-interface resource creation.
  # Example: { "az-gw-1-ge1" => { gw_key = "az-gw-1", intf_key = "ge1", subnet = {...} }, ... }
  gateway_subnets = merge([
    for gw_key, gw in local.gateways : {
      for intf_key, intf in gw.subnets :
      "${gw_key}-${intf_key}" => {
        gw_key   = gw_key
        intf_key = intf_key
        subnet   = intf
        az       = gw.availability_zone
      } if intf != null
    }
  ]...)

  # Public (WAN) interfaces only
  gw_public_interfaces = {
    for k, v in local.gateway_subnets : k => v
    if v.subnet.overlay == "public"
  }

  # LAN interfaces only
  gw_lan_interfaces = {
    for k, v in local.gateway_subnets : k => v
    if v.subnet.overlay == null
  }

  # First LAN interface key per gateway (e.g. "ge2")
  gw_lan_key = {
    for gw_key, gw in local.gateways : gw_key => [
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == null
      ][0] if length([
        for intf_key, intf in gw.subnets : intf_key
        if intf != null && intf.overlay == null
    ]) > 0
  }

  # RouteServerSubnet CIDR — /27 starting after all gateway subnets.
  # For subnet_size=28: gateway_count /27 blocks are consumed by gateway /28 pairs.
  route_server_subnet_cidr = var.azure_route_server.route_server_subnet_cidr != "" ? (
    var.azure_route_server.route_server_subnet_cidr
  ) : cidrsubnet(var.azure_network_config.vnet_cidr, 27 - local.vnet_prefix_len, var.gateway_count)
}
