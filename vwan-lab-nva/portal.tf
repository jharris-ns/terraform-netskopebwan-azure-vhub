#------------------------------------------------------------------------------
#  Netskope Portal Configuration: Gateways, Interfaces, BGP, Activation
#
#  All resources iterate over local.nvas (one per gateway) or derived maps.
#  Gateway names in the portal match the gateway key: "{gateway_prefix}-{n}".
#
#  BGP peers are the vhub built-in router IPs (two IPs for HA).
#  vhub router ASN: var.virtual_router_asn (always 65515 for Azure Virtual WAN).
#  NVA ASN: var.gateway_bgp_asn (default 400).
#------------------------------------------------------------------------------

# Allow the Netskope API to settle before creating child resources.
resource "time_sleep" "nsg_api_delay" {
  create_duration = "30s"
}

# --- Policy (shared across all gateways — must already exist on the tenant) ---

data "netskopebwan_policy" "existing" {
  name = var.gateway_policy
}

# --- Gateways ---

resource "netskopebwan_gateway" "nva" {
  for_each = local.nvas
  name     = each.key
  model    = "iXVirtual"
  role     = var.gateway_role

  assigned_policy {
    id   = data.netskopebwan_policy.existing.id
    name = data.netskopebwan_policy.existing.name
  }

  depends_on = [time_sleep.nsg_api_delay]
}

resource "time_sleep" "gw_propagation" {
  for_each        = local.nvas
  create_duration = "30s"
  triggers = {
    gateway_id = netskopebwan_gateway.nva[each.key].id
  }
}

# --- Activation (token injected into cloud-init via vm.tf) ---
# Must be created before the VM so the activation token is available for custom_data.

resource "netskopebwan_gateway_activate" "nva" {
  for_each           = local.nvas
  gateway_id         = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  timeout_in_seconds = 86400
}

# --- Interfaces: GE1 (WAN) ---

resource "netskopebwan_gateway_interface" "ge1" {
  for_each   = local.nvas
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "GE1"
  type       = "ethernet"

  addresses {
    address            = azurerm_network_interface.nva_ge1["${each.key}-ge1"].private_ip_address
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = "8.8.8.8"
    dns_secondary      = "8.8.4.4"
    gateway            = each.value.ge1_gateway
    mask               = cidrnetmask(each.value.ge1_subnet)
  }

  overlay_setting {
    is_backup           = false
    tx_bw_kbps          = 1000000
    rx_bw_kbps          = 1000000
    bw_measurement_mode = "manual"
    tag                 = "wired"
  }

  mtu         = 1500
  enable_nat  = true
  mode        = "routed"
  is_disabled = false
  zone        = "untrusted"
}

# --- Interfaces: GE2 (LAN) ---
# No overlay_setting — LAN traffic routes via explicit static routes only.

resource "netskopebwan_gateway_interface" "ge2" {
  for_each   = local.nvas
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "GE2"
  type       = "ethernet"

  addresses {
    address            = azurerm_network_interface.nva_ge2["${each.key}-ge2"].private_ip_address
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = "8.8.8.8"
    dns_secondary      = "8.8.4.4"
    gateway            = null
    mask               = cidrnetmask(each.value.ge2_subnet)
  }

  mtu         = null
  enable_nat  = false
  mode        = "routed"
  is_disabled = false
  zone        = "trusted"
}

# --- Static route: Azure IMDS ---
# Pins 169.254.169.254/32 to GE1 so the Netskope overlay (169.254.0.0/16)
# does not capture Azure metadata traffic.

resource "netskopebwan_gateway_staticroute" "metadata" {
  for_each    = local.nvas
  gateway_id  = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  advertise   = true
  destination = "169.254.169.254/32"
  device      = "GE1"
  install     = true
  nhop        = each.value.ge1_gateway
}

# --- BGP peer configuration: vhub router (two IPs per gateway for HA) ---
# local.nva_bgp_peers is a flat map: "{gw_key}-peer1" / "{gw_key}-peer2"

resource "netskopebwan_gateway_bgpconfig" "vhub_peer" {
  for_each   = local.nva_bgp_peers
  gateway_id = time_sleep.gw_propagation[each.value.gw_key].triggers["gateway_id"]
  name       = replace(each.key, "${each.value.gw_key}-", "vhub-")
  neighbor   = each.value.neighbor
  remote_as  = var.virtual_router_asn
}
