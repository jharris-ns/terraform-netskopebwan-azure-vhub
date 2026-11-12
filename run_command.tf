#------------------------------------------------------------------------------
#  Azure Run Command — Replaces AWS SSM Document + Send Command
#
#  AWS SSM equivalent mapping:
#    aws_ssm_document          → inline script in null_resource local-exec
#    aws ssm send-command      → az vm run-command invoke (synchronous)
#    ssm_send_command.sh       → scripts/azure_run_command.sh
#    SSM VPC Endpoints         → not needed (Azure VM Agent uses Azure fabric)
#    SSM agent (user-data)     → not needed (VM Agent is pre-installed)
#
#  Config push sequence (mirrors AWS SSM document steps):
#    Step 1: Activate gateway      (infhostd activate)
#    Step 2: Write FRR config      (frrcmds-user.json with Route Server BGP peers)
#    Step 3: Configure networking  (static routes, infhost restart)
#    Step 4: Verify BGP            (docker exec vtysh show bgp summary)
#
#  Key Azure difference from AWS:
#    - No GRE tunnel configuration (Route Server does direct eBGP, no GRE needed)
#    - BGP peers = Route Server virtual_router_ips (not TGW inside IPs)
#    - remote-as = 65515 (Route Server ASN, fixed by Azure)
#    - LAN interface name detected dynamically (not hardcoded like AWS enp2s1)
#
#  az vm run-command invoke output is limited to ~4KB.
#  Scripts are written to temp files and passed as @file to avoid size limits.
#------------------------------------------------------------------------------

locals {
  # Build per-gateway config payload for the run command
  run_configs = {
    for gw_key, gw in local.gateways : gw_key => {
      vm_name          = azurerm_linux_virtual_machine.gateways[gw_key].name
      lan_ip           = azurerm_network_interface.gw_interfaces["${gw_key}-${local.gw_lan_key[gw_key]}"].private_ip_address
      lan_gateway      = cidrhost(gw.subnets[local.gw_lan_key[gw_key]].subnet_cidr, 1)
      bgp_peer1        = local.route_server_peer_ips[0]
      bgp_peer2        = local.route_server_peer_ips[1]
      bgp_asn          = var.netskope_tenant.tenant_bgp_asn
      bgp_metric       = gw.bgp_metric
      static_routes    = join(",", var.netskope_gateway_config.static_routes)
      activation_token = netskopebwan_gateway_activate.gateways[gw_key].token
      tenant_uri       = "https://${local.tenant_url}"
      rs_subnet_cidr   = local.route_server_subnet_cidr
    }
  }
}

# --- BGP / Networking Config (replaces AWS gre_config SSM document + null_resource) ---

resource "null_resource" "gre_config" {
  for_each = local.run_configs

  triggers = {
    vm_name          = each.value.vm_name
    lan_ip           = each.value.lan_ip
    lan_gateway      = each.value.lan_gateway
    bgp_peer1        = each.value.bgp_peer1
    bgp_peer2        = each.value.bgp_peer2
    bgp_asn          = each.value.bgp_asn
    bgp_metric       = each.value.bgp_metric
    static_routes    = each.value.static_routes
    activation_token = each.value.activation_token
    tenant_uri       = each.value.tenant_uri
    rs_subnet_cidr   = each.value.rs_subnet_cidr
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${local.resource_group_name}"
      VM="${each.value.vm_name}"
      BGP_ASN="${each.value.bgp_asn}"
      BGP_PEER1="${each.value.bgp_peer1}"
      BGP_PEER2="${each.value.bgp_peer2}"
      BGP_METRIC="${each.value.bgp_metric}"
      LAN_IP="${each.value.lan_ip}"
      LAN_GW="${each.value.lan_gateway}"
      STATIC_ROUTES="${each.value.static_routes}"
      RS_SUBNET="${each.value.rs_subnet_cidr}"
      TOKEN="${each.value.activation_token}"
      TENANT_URI="${each.value.tenant_uri}"

      # Write the config script to a temp file to avoid command-line size limits
      # Note: macOS mktemp requires X's at the end of the template (no suffix after X's)
      TMPSCRIPT=$(mktemp "$${TMPDIR:-/tmp}/az_run_XXXXXX")
      mv "$TMPSCRIPT" "$${TMPSCRIPT}.sh"
      TMPSCRIPT="$${TMPSCRIPT}.sh"
      cat > "$TMPSCRIPT" << 'SCRIPTEOF'
#!/bin/bash
set -e

BGP_ASN="__BGP_ASN__"
BGP_PEER1="__BGP_PEER1__"
BGP_PEER2="__BGP_PEER2__"
BGP_METRIC="__BGP_METRIC__"
LAN_IP="__LAN_IP__"
LAN_GW="__LAN_GW__"
STATIC_ROUTES="__STATIC_ROUTES__"
RS_SUBNET="__RS_SUBNET__"
TOKEN="__TOKEN__"
TENANT_URI="__TENANT_URI__"

# -------------------------------------------------------
# STEP 1: Activate gateway
# -------------------------------------------------------
echo '=== Step 1: Activating gateway ==='
infhostd activate -uri "$TENANT_URI" -token "$TOKEN" \
  || echo 'Activation failed (gateway may already be activated) — continuing...'
echo 'Waiting 30s for activation to propagate...'
sleep 30

# -------------------------------------------------------
# STEP 2: Write FRR configuration
# Azure: BGP peers = Route Server IPs, remote-as = 65515
# (Route Server ASN is fixed by Azure at 65515)
# -------------------------------------------------------
echo '=== Step 2: Writing FRR configuration ==='
cat > /infroot/workdir/frrcmds-user.json << 'FRREOF'
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "ip community-list standard HA_COMMUNITY permit 47474:47474"
      ]
    },
    {
      "frrCmds": [
        "conf t",
        "ip prefix-list default seq 5 permit 0.0.0.0/0",
        "route-map advertise permit 10",
        "match ip address prefix-list default",
        "route-map set-med-peer permit 10",
        "set metric __BGP_METRIC__"
      ]
    },
    {
      "frrCmds": [
        "conf t",
        "router bgp __BGP_ASN__",
        "neighbor __BGP_PEER1__ remote-as 65515",
        "neighbor __BGP_PEER1__ disable-connected-check",
        "neighbor __BGP_PEER1__ ebgp-multihop 2",
        "neighbor __BGP_PEER1__ route-map set-med-peer out",
        "neighbor __BGP_PEER2__ remote-as 65515",
        "neighbor __BGP_PEER2__ disable-connected-check",
        "neighbor __BGP_PEER2__ ebgp-multihop 2",
        "neighbor __BGP_PEER2__ route-map set-med-peer out"
      ]
    },
    {
      "frrCmds": [
        "conf t",
        "route-map To-Ctrlr-1 deny 5",
        "match ip address prefix-list default",
        "route-map To-Ctrlr-2 deny 5",
        "match ip address prefix-list default",
        "route-map To-Ctrlr-3 deny 5",
        "match ip address prefix-list default",
        "route-map To-Ctrlr-4 deny 5",
        "match ip address prefix-list default"
      ]
    },
    {
      "frrCmds": [
        "route-map From-Ctrlr-1 deny 6",
        "match community HA_COMMUNITY",
        "route-map From-Ctrlr-2 deny 6",
        "match community HA_COMMUNITY",
        "route-map From-Ctrlr-3 deny 6",
        "match community HA_COMMUNITY",
        "route-map To-Ctrlr-3 permit 10",
        "set community 47474:47474 additive",
        "route-map To-Ctrlr-2 permit 10",
        "set community 47474:47474 additive",
        "route-map To-Ctrlr-1 permit 10",
        "set community 47474:47474 additive",
        "route-map To-Ctrlr-4 permit 10",
        "set community 47474:47474 additive"
      ]
    }
  ]
}
FRREOF
chmod 644 /infroot/workdir/frrcmds-user.json
chown root:root /infroot/workdir/frrcmds-user.json
echo 'FRR configuration written successfully.'

# -------------------------------------------------------
# STEP 3: Configure networking for Azure Route Server
#
# Azure Route Server does direct eBGP — no GRE tunnel needed.
# We only need to:
#   1. Detect the LAN NIC name dynamically (not hardcoded like AWS enp2s1)
#   2. Add a route for the Route Server subnet via the LAN gateway
#   3. Install any additional static routes
#   4. Restart the infhost service and container
# -------------------------------------------------------
echo '=== Step 3: Configuring Azure networking ==='

# Detect LAN NIC by matching its private IP
LAN_INTF=$(ip -o addr show | awk -v ip="$LAN_IP" '$0 ~ ip {gsub(/:/, "", $2); print $2}' | head -1)
if [ -z "$LAN_INTF" ]; then
  echo "ERROR: Could not detect LAN interface for IP $LAN_IP"
  ip addr show
  exit 1
fi
echo "Detected LAN interface: $LAN_INTF (IP: $LAN_IP)"

# Route for Route Server subnet — BGP traffic from the gateway's LAN IP
# to the Route Server must use the LAN interface (not the default WAN route).
echo "Adding Route Server subnet route: $RS_SUBNET via $LAN_GW dev $LAN_INTF"
ip route replace "$RS_SUBNET" via "$LAN_GW" dev "$LAN_INTF" 2>/dev/null || \
  echo "Route may already exist or LAN GW not yet reachable — continuing..."

# Install additional static routes via LAN
if [ -n "$STATIC_ROUTES" ]; then
  IFS=',' read -ra CIDRS <<< "$STATIC_ROUTES"
  for CIDR in "$${CIDRS[@]}"; do
    [ -z "$CIDR" ] && continue
    ip route replace "$CIDR" via "$LAN_GW" dev "$LAN_INTF" 2>/dev/null || true
    echo "  Added static route: $CIDR via $LAN_GW dev $LAN_INTF"
  done
fi

echo 'Restarting infhost service...'
service infhost restart || true
echo 'Restarting infhost container...'
infhostd restart-container
echo 'Waiting 15s for container to start...'
sleep 15

# Re-add Route Server subnet route (container restart may clear host routes)
ip route replace "$RS_SUBNET" via "$LAN_GW" dev "$LAN_INTF" table 101 2>/dev/null || true
echo 'Networking configured successfully.'

# -------------------------------------------------------
# STEP 4: Verify BGP configuration
# -------------------------------------------------------
echo '=== Step 4: Verifying BGP configuration ==='
MAX_ATTEMPTS=12
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  RUNNING=$(docker inspect -f '{{.State.Running}}' infiot_spoke 2>/dev/null || echo 'false')
  [ "$RUNNING" = "true" ] && break
  ATTEMPT=$((ATTEMPT + 1))
  echo "Waiting for container... attempt $ATTEMPT/$MAX_ATTEMPTS"
  sleep 10
done
echo 'Container is running. Waiting 30s for FRR to initialize...'
sleep 30

BGP_CHECK=$(docker exec infiot_spoke vtysh -c 'show bgp summary' 2>/dev/null \
  | grep -c "$BGP_PEER1" || true)
if [ "$BGP_CHECK" -eq 0 ]; then
  echo 'BGP neighbors not found after first restart. Retrying container restart...'
  infhostd restart-container
  sleep 60
  BGP_CHECK=$(docker exec infiot_spoke vtysh -c 'show bgp summary' 2>/dev/null \
    | grep -c "$BGP_PEER1" || true)
  if [ "$BGP_CHECK" -eq 0 ]; then
    echo 'WARNING: BGP neighbors still not configured. Manual check may be needed.'
    exit 0
  fi
fi
echo 'BGP configuration verified:'
docker exec infiot_spoke vtysh -c 'show bgp summary'
SCRIPTEOF

      # Substitute runtime values into the script (double-underscore placeholders)
      # Use sed -i '' for macOS (BSD sed) compatibility; also works with GNU sed.
      sed -i '' "s|__BGP_ASN__|$BGP_ASN|g"      "$TMPSCRIPT"
      sed -i '' "s|__BGP_PEER1__|$BGP_PEER1|g"  "$TMPSCRIPT"
      sed -i '' "s|__BGP_PEER2__|$BGP_PEER2|g"  "$TMPSCRIPT"
      sed -i '' "s|__BGP_METRIC__|$BGP_METRIC|g" "$TMPSCRIPT"
      sed -i '' "s|__LAN_IP__|$LAN_IP|g"         "$TMPSCRIPT"
      sed -i '' "s|__LAN_GW__|$LAN_GW|g"         "$TMPSCRIPT"
      sed -i '' "s|__STATIC_ROUTES__|$STATIC_ROUTES|g" "$TMPSCRIPT"
      sed -i '' "s|__RS_SUBNET__|$RS_SUBNET|g"   "$TMPSCRIPT"
      sed -i '' "s|__TOKEN__|$TOKEN|g"           "$TMPSCRIPT"
      sed -i '' "s|__TENANT_URI__|$TENANT_URI|g" "$TMPSCRIPT"

      chmod +x "$TMPSCRIPT"

      # Invoke via shared helper (polls VM running state, then invokes synchronously)
      ${path.module}/scripts/azure_run_command.sh \
        "$RG" "$VM" "$TMPSCRIPT" \
        "Configure BGP/networking on gateway ${each.key}" \
        "${var.azure_network_config.subscription_id}"

      rm -f "$TMPSCRIPT"
    EOT
  }
}

# --- SSE Monitor Deployment (replaces AWS SSM-based sse_monitor deployment) ---
# Deploys the IPsec health monitor that manages BGP default route advertisement.
# The sse_monitor.sh script is identical to the AWS version — only delivery changes.
# Files deployed: sse_monitor.sh, sse_monitor.service, sse_monitor.logrotate,
#                 frrcmds-advertise-default.json, frrcmds-retract-default.json,
#                 frrcmds-block-default-redistribute.json

resource "null_resource" "sse_monitor" {
  for_each   = local.run_configs
  depends_on = [null_resource.gre_config]

  triggers = {
    vm_name     = each.value.vm_name
    bgp_asn     = each.value.bgp_asn
    bgp_peer1   = each.value.bgp_peer1
    bgp_peer2   = each.value.bgp_peer2
    script_hash = filesha256("${path.module}/scripts/sse_monitor.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${local.resource_group_name}"
      VM="${each.value.vm_name}"
      BGP_ASN="${each.value.bgp_asn}"
      BGP_PEER1="${each.value.bgp_peer1}"
      BGP_PEER2="${each.value.bgp_peer2}"

      # Build the SSE monitor tar payload locally (same approach as AWS)
      SSEDIR=$(mktemp -d)
      mkdir -p "$SSEDIR/root/sse_monitor"
      mkdir -p "$SSEDIR/etc/systemd/system"
      mkdir -p "$SSEDIR/etc/logrotate.d"

      cp "${path.module}/scripts/sse_monitor.sh"      "$SSEDIR/root/sse_monitor/sse_monitor.sh"
      cp "${path.module}/scripts/sse_monitor.service"  "$SSEDIR/etc/systemd/system/sse_monitor.service"
      cp "${path.module}/scripts/sse_monitor.logrotate" "$SSEDIR/etc/logrotate.d/sse_monitor"

      # Generate per-gateway FRR command files for BGP route advertisement control
      cat > "$SSEDIR/root/sse_monitor/frrcmds-block-default-redistribute.json" << 'BLKEOF'
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "route-map set-med-peer deny 5",
        "match ip address prefix-list default"
      ]
    }
  ]
}
BLKEOF

      cat > "$SSEDIR/root/sse_monitor/frrcmds-advertise-default.json" << 'ADVEOF'
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "no route-map set-med-peer deny 5"
      ]
    }
  ]
}
ADVEOF

      cat > "$SSEDIR/root/sse_monitor/frrcmds-retract-default.json" << 'RETEOF'
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "route-map set-med-peer deny 5",
        "match ip address prefix-list default"
      ]
    }
  ]
}
RETEOF

      # Create base64-encoded tar payload
      PAYLOAD=$(cd "$SSEDIR" && tar czf - root etc | base64 | tr -d '\n')
      rm -rf "$SSEDIR"

      # Write deployment script to temp file
      # Note: macOS mktemp requires X's at the end of the template (no suffix after X's)
      TMPSCRIPT=$(mktemp "$${TMPDIR:-/tmp}/az_sse_XXXXXX")
      mv "$TMPSCRIPT" "$${TMPSCRIPT}.sh"
      TMPSCRIPT="$${TMPSCRIPT}.sh"
      cat > "$TMPSCRIPT" << SSEEOF
#!/bin/bash
set -e
echo '__PAYLOAD__' | base64 -d | tar xz --no-overwrite-dir -C /
chmod 755 /root/sse_monitor/sse_monitor.sh
systemctl daemon-reload
systemctl enable sse_monitor
systemctl restart sse_monitor
echo 'SSE monitor deployed successfully.'
SSEEOF

      # Substitute payload (must be on one line, no special chars in sed boundary)
      # Use Python for the substitution to handle large payloads safely
      python3 -c "
import sys
with open('$TMPSCRIPT', 'r') as f:
    content = f.read()
content = content.replace('__PAYLOAD__', '''$PAYLOAD''')
with open('$TMPSCRIPT', 'w') as f:
    f.write(content)
"

      chmod +x "$TMPSCRIPT"

      ${path.module}/scripts/azure_run_command.sh \
        "$RG" "$VM" "$TMPSCRIPT" \
        "Deploy SSE monitor on gateway ${each.key}" \
        "${var.azure_network_config.subscription_id}"

      rm -f "$TMPSCRIPT"
    EOT
  }
}
