#!/bin/bash
#
# SSE monitor — IPsec tunnel health monitor for the Netskope BWAN gateway.
#
# Controls advertisement of 0.0.0.0/0 to the vhub router peers based on tunnel
# health, and keeps the static route to the vhub prefix installed.
#
# Upgrade survival: everything this script needs lives in /infroot/sse_monitor/
# (the only partition that survives a BWAN rootfs upgrade). It is started by the
# "sse_monitor" launcher container (docker --restart unless-stopped), which
# nsenters the host namespaces and runs this script on the host. Nothing is
# installed under /root or /etc. See docs/DEVOPS_NOTES.md.

# Configuration
BASE_DIR=/infroot/sse_monitor
CONTAINER_NAME="infiot_spoke"
LOG_FILE="/var/log/sse_monitor.log"
LOG_MAX_BYTES=104857600  # 100 MB; rotated in-script (no logrotate file to lose on upgrade)
STABILIZATION_TIME=30    # Seconds to wait after restart for FRR to stabilize
ADVERTISE_FILE=$BASE_DIR/frrcmds-advertise-default.json
RETRACT_FILE=$BASE_DIR/frrcmds-retract-default.json
BLOCK_REDIST_FILE=$BASE_DIR/frrcmds-block-default-redistribute.json

# Site parameters written by Terraform (run_command.tf): VHUB_PREFIX, LAN_GW, LAN_IP
VHUB_PREFIX=""
LAN_GW=""
LAN_IP=""
if [ -f "$BASE_DIR/monitor.env" ]; then
  # shellcheck disable=SC1091
  . "$BASE_DIR/monitor.env"
fi

# Initialize tracking variables
last_start_time=""
retracted=1  # 0 = Advertised, 1 = Retracted (start retracted to force initial advertise)

log() {
  echo "$(date) $*" >> "$LOG_FILE"
}

rotate_log() {
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

# The route to the vhub router IPs via the LAN gateway is runtime-only: it is
# lost on reboot, on rootfs upgrade and on container restart. Re-assert it on
# every loop; only log when it had to be (re)added.
ensure_vhub_route() {
  if [ -z "$VHUB_PREFIX" ] || [ -z "$LAN_GW" ] || [ -z "$LAN_IP" ]; then
    return 0
  fi

  local intf
  intf=$(ip -o -4 addr show | awk -v ip="$LAN_IP" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}')
  if [ -z "$intf" ]; then
    return 0  # LAN interface not addressed yet — retry on the next loop
  fi

  if ! ip route show "$VHUB_PREFIX" 2>/dev/null | grep -q "via $LAN_GW dev $intf"; then
    if ip route replace "$VHUB_PREFIX" via "$LAN_GW" dev "$intf" 2>/dev/null; then
      log "ACTION: vhub route $VHUB_PREFIX via $LAN_GW dev $intf added (main table)."
    else
      log "ERROR: Failed to add vhub route $VHUB_PREFIX via $LAN_GW dev $intf (main table)."
    fi
  fi

  if ! ip route show "$VHUB_PREFIX" table 101 2>/dev/null | grep -q "via $LAN_GW dev $intf"; then
    if ip route replace "$VHUB_PREFIX" via "$LAN_GW" dev "$intf" table 101 2>/dev/null; then
      log "ACTION: vhub route $VHUB_PREFIX via $LAN_GW dev $intf added (table 101)."
    fi
  fi
}

# Read the real state of the outbound filter from FRR instead of trusting the
# remembered flag. Fail-closed design: frrcmds-user.json carries the deny rule,
# so anything that re-applies that file puts the deny back behind our back.
#   returns 0 = deny present (default route withheld)
#           1 = deny absent  (default route advertised)
#           2 = unknown      (vtysh failed or output not recognised)
deny_state() {
  local cfg
  cfg=$(docker exec $CONTAINER_NAME vtysh -c 'show running-config' 2>/dev/null)
  if ! echo "$cfg" | grep -q '^route-map set-med-peer permit 10'; then
    return 2
  fi
  if echo "$cfg" | grep -q '^route-map set-med-peer deny 5'; then
    return 0
  fi
  return 1
}

state_check_ok=0  # 1 once deny_state has been proven to detect the deny rule

log "Process $$: Starting SSE Monitor for $CONTAINER_NAME..."

while true
do
  rotate_log
  ensure_vhub_route

  # --------------------------------
  # STEP 1: Check Container Status & Timestamp
  # --------------------------------

  current_start_time=$(docker inspect --format='{{.State.StartedAt}}' $CONTAINER_NAME 2>/dev/null)

  # If empty, the container is down. Wait and retry.
  if [ -z "$current_start_time" ]; then
    log "Container $CONTAINER_NAME not found/down. Waiting..."
    sleep 10
    continue
  fi

  # --------------------------------
  # STEP 2: Detect Restart & Stabilize
  # --------------------------------

  if [ "$current_start_time" != "$last_start_time" ]; then
    if [ -n "$last_start_time" ]; then
      log "RESTART DETECTED (New Start Time: $current_start_time)."
    fi

    log "Waiting ${STABILIZATION_TIME}s for BGP/FRR to stabilize..."

    # This sleep is CRITICAL. It lets FRR finish loading its default config.
    sleep $STABILIZATION_TIME

    # A container start can flush the vhub route — re-assert it before BGP needs it.
    ensure_vhub_route

    # Block redistributed 0.0.0.0/0 from leaking to the vhub router peers via
    # set-med-peer until the first tunnel check passes.
    if [ -f "$BLOCK_REDIST_FILE" ]; then
      log "Applying route-map deny for redistributed default route..."
      docker cp $BLOCK_REDIST_FILE $CONTAINER_NAME:/tmp/frrcmds-block-default-redistribute.json >> "$LOG_FILE" 2>&1
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-block-default-redistribute.json >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: Redistributed default route blocked in set-med-peer."
      else
        log "ERROR: Failed to apply redistribute block rule."
      fi
    fi

    # Self-test the state check: the deny rule must be present right now (it is
    # in frrcmds-user.json and was just re-applied above). If deny_state cannot
    # see it, its output parsing does not fit this FRR version — fall back to
    # the remembered flag rather than act on a wrong reading.
    deny_state
    if [ $? -eq 0 ]; then
      state_check_ok=1
    else
      state_check_ok=0
      log "WARNING: Could not confirm deny rule in FRR running-config. Live state check disabled; using remembered state."
    fi

    # Start in retracted state so the monitor always pushes the advertise config
    # when tunnels are up. This handles both fresh boots and container restarts.
    retracted=1

    # Update the last known start time so we don't trigger this block again.
    last_start_time="$current_start_time"

    log "Stabilization complete. Checking tunnels now."
  fi

  # --------------------------------
  # STEP 3: Monitor Tunnels & Manage Route
  # --------------------------------

  # Get tunnel count safely
  sse_tunnel_count=$(docker exec $CONTAINER_NAME ikectl show sa 2>/dev/null | grep ESTABLISHED | grep "@infiot.com" | wc -l)

  # Safety check: if variable is empty, treat as 0
  if [ -z "$sse_tunnel_count" ]; then sse_tunnel_count=0; fi

  log "Tunnel Count=$sse_tunnel_count"

  # Reconcile the remembered flag with what FRR actually has configured.
  if [ "$state_check_ok" -eq 1 ]; then
    deny_state
    actual=$?
    if [ "$actual" -eq 0 ] && [ "$retracted" -eq 0 ]; then
      log "DRIFT: deny rule is back in FRR (config re-applied?). Marking route as retracted."
      retracted=1
    elif [ "$actual" -eq 1 ] && [ "$retracted" -eq 1 ]; then
      log "DRIFT: deny rule missing from FRR while route should be retracted. Marking route as advertised."
      retracted=0
    fi
  fi

  if [ "$sse_tunnel_count" -eq 0 ]; then
    # --- SCENARIO: TUNNELS DOWN ---

    # If tunnels are down and we haven't retracted yet, DO IT.
    if [ "$retracted" -eq 0 ]; then
      log "ACTION: Tunnels Down. Retracting default route..."

      # Copy config into container and run
      docker cp $RETRACT_FILE $CONTAINER_NAME:/tmp/frrcmds-retract-default.json >> "$LOG_FILE" 2>&1
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-retract-default.json >> "$LOG_FILE" 2>&1; then
        retracted=1
        log "SUCCESS: Route Retracted."
      else
        log "ERROR: Failed to retract route (Command failed)."
      fi
    else
      log "Route already retracted. No action."
    fi

  else

    # --- SCENARIO: TUNNELS UP ---

    # If tunnels are up and we previously retracted, RE-ADVERTISE.
    if [ "$retracted" -eq 1 ]; then
      log "ACTION: Tunnels Up. Re-advertising default route..."

      docker cp $ADVERTISE_FILE $CONTAINER_NAME:/tmp/frrcmds-advertise-default.json >> "$LOG_FILE" 2>&1
      if docker exec $CONTAINER_NAME /opt/infiot/bin/gencfg -run-frr-cmds /tmp/frrcmds-advertise-default.json >> "$LOG_FILE" 2>&1; then
        retracted=0
        log "SUCCESS: Route Advertised."
      else
        log "ERROR: Failed to advertise route."
      fi
    fi

  fi

  sleep 10

done

# End Of Script #
