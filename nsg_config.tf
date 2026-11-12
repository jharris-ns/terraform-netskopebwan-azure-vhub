#------------------------------------------------------------------------------
#  Netskope Portal Configuration: Policy, Gateways, Interfaces, BGP, Activation
#
#  This file is nearly identical to the AWS version. The Netskope provider
#  resources are cloud-agnostic — only the IP source changes (Azure NIC vs AWS ENI).
#
#  BGP peer change from AWS:
#    AWS:   BGP peers = TGW GRE inside IPs (e.g. 169.254.x.2, 169.254.x.3)
#    Azure: BGP peers = Route Server virtual_router_ips (2 IPs from RouteServerSubnet)
#           remote_as = 65515 (Route Server ASN, fixed by Azure)
#------------------------------------------------------------------------------

# --- API propagation delay ---

resource "time_sleep" "nsg_api_delay" {
  create_duration = "30s"
}

# --- Locals ---

locals {
  # Flatten all interfaces for Netskope API configuration
  nsg_all_interfaces = merge([
    for gw_key, gw in local.gateways : {
      for intf_key, intf in gw.subnets :
      "${gw_key}-${intf_key}" => {
        gw_key   = gw_key
        intf_key = intf_key
        subnet   = intf
      } if intf != null
    }
  ]...)

  nsg_public_interfaces = {
    for k, v in local.nsg_all_interfaces : k => v
    if v.subnet.overlay == "public"
  }

  nsg_private_interfaces = {
    for k, v in local.nsg_all_interfaces : k => v
    if try(v.subnet.overlay, null) == "private"
  }

  # First public interface per gateway (for metadata static route)
  nsg_gw_public_key = {
    for gw_key, gw in local.gateways : gw_key => [
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == "public"
      ][0] if length([
        for intf_key, intf in gw.subnets : intf_key
        if intf != null && intf.overlay == "public"
    ]) > 0
  }

  # Route Server peer IPs — always 2 IPs per Route Server instance.
  # These replace the TGW GRE inside IPs used in the AWS version.
  # Sort for stable ordering — Terraform sets have non-deterministic iteration order
  route_server_peer_ips = sort(tolist(azurerm_route_server.this.virtual_router_ips))
}

# --- Policy (must exist on the Netskope tenant) ---

data "netskopebwan_policy" "existing" {
  name = var.netskope_gateway_config.gateway_policy
}

locals {
  policy_id   = data.netskopebwan_policy.existing.id
  policy_name = data.netskopebwan_policy.existing.name
}

# --- Gateway Resources ---

resource "netskopebwan_gateway" "gateways" {
  for_each = local.gateways
  name     = coalesce(each.value.gateway_name, each.key)
  model    = var.netskope_gateway_config.gateway_model
  role     = each.value.gateway_role
  assigned_policy {
    id   = local.policy_id
    name = local.policy_name
  }
}

resource "time_sleep" "gw_propagation" {
  for_each        = local.gateways
  create_duration = "30s"

  triggers = {
    gateway_id = netskopebwan_gateway.gateways[each.key].id
  }
}

# --- Interface Configuration ---

resource "netskopebwan_gateway_interface" "gw_interfaces" {
  for_each   = local.nsg_all_interfaces
  gateway_id = time_sleep.gw_propagation[each.value.gw_key].triggers["gateway_id"]
  name       = upper(each.value.intf_key)
  type       = "ethernet"
  addresses {
    address            = azurerm_network_interface.gw_interfaces[each.key].private_ip_address
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = var.netskope_gateway_config.dns_primary
    dns_secondary      = var.netskope_gateway_config.dns_secondary
    # Default gateway only on WAN/overlay interfaces. LAN interfaces (GE2) have
    # no default gateway — traffic routes via explicit static routes only.
    # Azure subnet gateway is always the first usable IP (cidrhost(..., 1)).
    gateway = contains(keys(merge(local.nsg_public_interfaces, local.nsg_private_interfaces)), each.key) ? cidrhost(local.gateways[each.value.gw_key].subnets[each.value.intf_key].subnet_cidr, 1) : null
    mask    = cidrnetmask(local.gateways[each.value.gw_key].subnets[each.value.intf_key].subnet_cidr)
  }
  dynamic "overlay_setting" {
    for_each = contains(keys(merge(local.nsg_public_interfaces, local.nsg_private_interfaces)), each.key) ? [1] : []
    content {
      is_backup           = false
      tx_bw_kbps          = 1000000
      rx_bw_kbps          = 1000000
      bw_measurement_mode = "manual"
      tag                 = contains(keys(local.nsg_public_interfaces), each.key) ? "wired" : "private"
    }
  }
  mtu         = contains(keys(merge(local.nsg_public_interfaces, local.nsg_private_interfaces)), each.key) ? var.netskope_gateway_config.wan_mtu : null
  enable_nat  = contains(keys(local.nsg_public_interfaces), each.key)
  mode        = "routed"
  is_disabled = false
  zone        = contains(keys(local.nsg_public_interfaces), each.key) ? "untrusted" : "trusted"
}

# --- Static Route: Azure Instance Metadata Service (IMDS) ---
# Pin 169.254.169.254/32 to the WAN interface to prevent the Netskope overlay
# (169.254.0.0/16) from capturing Azure metadata traffic.

resource "netskopebwan_gateway_staticroute" "metadata" {
  for_each    = local.nsg_gw_public_key
  gateway_id  = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  advertise   = true
  destination = "169.254.169.254/32"
  device      = "GE1"
  install     = true
  nhop        = cidrhost(local.gateways[each.key].subnets[each.value].subnet_cidr, 1)
}

# --- Gateway Activation ---

resource "netskopebwan_gateway_activate" "gateways" {
  for_each           = local.gateways
  gateway_id         = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  timeout_in_seconds = 86400
}

# --- BGP Peer Configuration (Netskope management plane) ---
# In Azure, BGP peers are the Route Server's virtual_router_ips (2 IPs).
# remote_as = 65515 (Route Server ASN, fixed by Azure).
# This mirrors the AWS version which used TGW inside IPs with tgw_asn.

resource "netskopebwan_gateway_bgpconfig" "rs_peer1" {
  for_each   = local.gateways
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "rs-peer-1-${each.key}"
  neighbor   = local.route_server_peer_ips[0]
  remote_as  = 65515
}

resource "netskopebwan_gateway_bgpconfig" "rs_peer2" {
  for_each   = local.gateways
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "rs-peer-2-${each.key}"
  neighbor   = local.route_server_peer_ips[1]
  remote_as  = 65515
}
