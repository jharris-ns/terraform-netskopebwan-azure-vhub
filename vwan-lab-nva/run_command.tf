#------------------------------------------------------------------------------
#  Azure Run Command — BGP / Networking Config and SSE Monitor
#
#  Both null_resources use for_each = local.nvas so they scale with gateway_count.
#
#  Key difference from the parent (Route Server) project: RS_SUBNET is replaced
#  by VHUB_PREFIX (the vhub address prefix, e.g. 10.0.0.0/24). This routes BGP
#  traffic destined for the vhub router IPs via the LAN interface.
#
#  macOS sed -i requires '' (BSD sed). Do not change to GNU sed syntax.
#------------------------------------------------------------------------------

locals {
  run_configs = {
    for gw_key, gw in local.nvas : gw_key => {
      vm_name          = azurerm_linux_virtual_machine.nva[gw_key].name
      lan_ip           = azurerm_network_interface.nva_ge2["${gw_key}-ge2"].private_ip_address
      lan_gateway      = gw.ge2_gateway
      bgp_peer1        = local.vhub_peer_ips[0]
      bgp_peer2        = local.vhub_peer_ips[1]
      bgp_asn          = tostring(var.gateway_bgp_asn)
      bgp_metric       = "10"
      vhub_prefix      = var.vhub_address_prefix
      activation_token = netskopebwan_gateway_activate.nva[gw_key].token
      tenant_uri       = "https://${local.tenant_url}"
      subscription_id  = var.subscription_id
    }
  }
}

# --- BGP / Networking Config ---

resource "null_resource" "bgp_config" {
  for_each = local.nvas

  triggers = {
    vm_name          = local.run_configs[each.key].vm_name
    lan_ip           = local.run_configs[each.key].lan_ip
    lan_gateway      = local.run_configs[each.key].lan_gateway
    bgp_peer1        = local.run_configs[each.key].bgp_peer1
    bgp_peer2        = local.run_configs[each.key].bgp_peer2
    bgp_asn          = local.run_configs[each.key].bgp_asn
    bgp_metric       = local.run_configs[each.key].bgp_metric
    vhub_prefix      = local.run_configs[each.key].vhub_prefix
    activation_token = local.run_configs[each.key].activation_token
    tenant_uri       = local.run_configs[each.key].tenant_uri
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${local.resource_group_name}"
      VM="${local.run_configs[each.key].vm_name}"
      BGP_ASN="${local.run_configs[each.key].bgp_asn}"
      BGP_PEER1="${local.run_configs[each.key].bgp_peer1}"
      BGP_PEER2="${local.run_configs[each.key].bgp_peer2}"
      BGP_METRIC="${local.run_configs[each.key].bgp_metric}"
      LAN_IP="${local.run_configs[each.key].lan_ip}"
      LAN_GW="${local.run_configs[each.key].lan_gateway}"
      VHUB_PREFIX="${local.run_configs[each.key].vhub_prefix}"
      TOKEN="${local.run_configs[each.key].activation_token}"
      TENANT_URI="${local.run_configs[each.key].tenant_uri}"

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
VHUB_PREFIX="__VHUB_PREFIX__"
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
        "match ip address prefix-list default",
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
# STEP 3: Configure networking for vhub BGP
# -------------------------------------------------------
echo '=== Step 3: Configuring networking for vhub BGP ==='

LAN_INTF=$(ip -o addr show | awk -v ip="$LAN_IP" '$0 ~ ip {gsub(/:/, "", $2); print $2}' | head -1)
if [ -z "$LAN_INTF" ]; then
  echo "ERROR: Could not detect LAN interface for IP $LAN_IP"
  ip addr show
  exit 1
fi
echo "Detected LAN interface: $LAN_INTF (IP: $LAN_IP)"

ip route replace "$VHUB_PREFIX" via "$LAN_GW" dev "$LAN_INTF" 2>/dev/null || \
  echo "Route may already exist — continuing..."

echo 'Restarting infhost service...'
service infhost restart || true
echo 'Restarting infhost container...'
infhostd restart-container
echo 'Waiting 15s for container to start...'
sleep 15

ip route replace "$VHUB_PREFIX" via "$LAN_GW" dev "$LAN_INTF" 2>/dev/null || true
ip route replace "$VHUB_PREFIX" via "$LAN_GW" dev "$LAN_INTF" table 101 2>/dev/null || true
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

      sed -i '' "s|__BGP_ASN__|$BGP_ASN|g"        "$TMPSCRIPT"
      sed -i '' "s|__BGP_PEER1__|$BGP_PEER1|g"    "$TMPSCRIPT"
      sed -i '' "s|__BGP_PEER2__|$BGP_PEER2|g"    "$TMPSCRIPT"
      sed -i '' "s|__BGP_METRIC__|$BGP_METRIC|g"  "$TMPSCRIPT"
      sed -i '' "s|__LAN_IP__|$LAN_IP|g"           "$TMPSCRIPT"
      sed -i '' "s|__LAN_GW__|$LAN_GW|g"           "$TMPSCRIPT"
      sed -i '' "s|__VHUB_PREFIX__|$VHUB_PREFIX|g" "$TMPSCRIPT"
      sed -i '' "s|__TOKEN__|$TOKEN|g"             "$TMPSCRIPT"
      sed -i '' "s|__TENANT_URI__|$TENANT_URI|g"   "$TMPSCRIPT"

      chmod +x "$TMPSCRIPT"

      ${path.module}/scripts/azure_run_command.sh \
        "$RG" "$VM" "$TMPSCRIPT" \
        "Configure BGP/networking on ${each.key}" \
        "${local.run_configs[each.key].subscription_id}"

      rm -f "$TMPSCRIPT"
    EOT
  }

  depends_on = [
    azurerm_linux_virtual_machine.nva,
    azurerm_virtual_hub_bgp_connection.nva,
    netskopebwan_gateway_bgpconfig.vhub_peer,
  ]
}

# --- SSE Monitor ---

resource "null_resource" "sse_monitor" {
  for_each   = local.nvas
  depends_on = [null_resource.bgp_config]

  triggers = {
    vm_name     = local.run_configs[each.key].vm_name
    bgp_peer1   = local.run_configs[each.key].bgp_peer1
    bgp_peer2   = local.run_configs[each.key].bgp_peer2
    bgp_asn     = local.run_configs[each.key].bgp_asn
    script_hash = filesha256("${path.module}/scripts/sse_monitor.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      RG="${local.resource_group_name}"
      VM="${local.run_configs[each.key].vm_name}"
      BGP_ASN="${local.run_configs[each.key].bgp_asn}"
      BGP_PEER1="${local.run_configs[each.key].bgp_peer1}"
      BGP_PEER2="${local.run_configs[each.key].bgp_peer2}"

      SSEDIR=$(mktemp -d)
      mkdir -p "$SSEDIR/root/sse_monitor"
      mkdir -p "$SSEDIR/etc/systemd/system"
      mkdir -p "$SSEDIR/etc/logrotate.d"

      cp "${path.module}/scripts/sse_monitor.sh"        "$SSEDIR/root/sse_monitor/sse_monitor.sh"
      cp "${path.module}/scripts/sse_monitor.service"   "$SSEDIR/etc/systemd/system/sse_monitor.service"
      cp "${path.module}/scripts/sse_monitor.logrotate" "$SSEDIR/etc/logrotate.d/sse_monitor"

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

      PAYLOAD=$(cd "$SSEDIR" && tar czf - root etc | base64 | tr -d '\n')
      rm -rf "$SSEDIR"

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
        "Deploy SSE monitor on ${each.key}" \
        "${local.run_configs[each.key].subscription_id}"

      rm -f "$TMPSCRIPT"
    EOT
  }
}
