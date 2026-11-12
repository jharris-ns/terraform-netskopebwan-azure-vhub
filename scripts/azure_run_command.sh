#!/bin/bash
# Azure Run Command helper — replaces ssm_send_command.sh from the AWS project.
#
# Usage: azure_run_command.sh <resource_group> <vm_name> <script_file> <comment>
#
# AWS equivalent:
#   ssm_send_command.sh polls describe-instance-information, sends SSM command,
#   then polls get-command-invocation until done.
#
# Azure simplification:
#   az vm run-command invoke is SYNCHRONOUS — it blocks until the script completes.
#   No polling loop needed after invocation.
#
# Prerequisites:
#   - az CLI installed and authenticated (az login or ARM_* env vars)
#   - jq installed (for parsing run-command output)
#
# Exit codes:
#   0 — script executed successfully on the VM
#   1 — VM not ready, authentication failure, or script returned non-zero exit

set -euo pipefail

RESOURCE_GROUP="$1"
VM_NAME="$2"
SCRIPT_FILE="$3"
COMMENT="$4"
SUBSCRIPTION="${5:-${AZURE_SUBSCRIPTION_ID:-}}"

# Build optional --subscription flag for all az calls
SUB_FLAG=()
if [ -n "$SUBSCRIPTION" ]; then
  SUB_FLAG=(--subscription "$SUBSCRIPTION")
fi

# --- Poll for VM running state (up to 5 minutes, 10s intervals) ---
MAX_ATTEMPTS=30
ATTEMPT=0
STATE="None"

echo "Waiting for VM $VM_NAME to be in running state..."
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  STATE=$(az vm get-instance-view \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    "${SUB_FLAG[@]}" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" \
    --output tsv 2>/dev/null || echo "None")
  if [ "$STATE" = "PowerState/running" ]; then
    echo "VM $VM_NAME is running."
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  echo "  VM state: $STATE — attempt $ATTEMPT/$MAX_ATTEMPTS (retry in 10s)"
  sleep 10
done

if [ "$STATE" != "PowerState/running" ]; then
  echo "ERROR: VM $VM_NAME did not reach running state after $(( MAX_ATTEMPTS * 10 ))s"
  exit 1
fi

# --- Also wait for the Azure VM Agent to be ready ---
AGENT_ATTEMPT=0
AGENT_STATUS="NotReady"
echo "Waiting for Azure VM Agent to become ready..."
while [ $AGENT_ATTEMPT -lt 30 ]; do
  AGENT_STATUS=$(az vm get-instance-view \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    "${SUB_FLAG[@]}" \
    --query "instanceView.vmAgent.statuses[0].code" \
    --output tsv 2>/dev/null || echo "ProvisioningState/unknown")
  if [ "$AGENT_STATUS" = "ProvisioningState/succeeded" ]; then
    echo "Azure VM Agent is ready."
    break
  fi
  AGENT_ATTEMPT=$((AGENT_ATTEMPT + 1))
  echo "  Agent status: $AGENT_STATUS — attempt $AGENT_ATTEMPT/30 (retry in 10s)"
  sleep 10
done

if [ "$AGENT_STATUS" != "ProvisioningState/succeeded" ]; then
  echo "WARNING: VM Agent may not be ready ($AGENT_STATUS) — proceeding anyway"
fi

# --- Invoke the run command (synchronous — blocks until script completes) ---
echo "Running: $COMMENT"
echo "  VM: $VM_NAME (RG: $RESOURCE_GROUP)"
echo "  Script: $SCRIPT_FILE ($(wc -c < "$SCRIPT_FILE") bytes)"

# az vm run-command invoke blocks until the script finishes.
# Output is limited to ~4KB; critical status lines are printed by the script.
# Script content is read with $(cat) — this is more reliable than @file syntax
# across Azure CLI versions, and handles scripts up to ~128KB (shell ARG_MAX).
SCRIPT_CONTENT=$(cat "$SCRIPT_FILE")

RESULT=$(az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  "${SUB_FLAG[@]}" \
  --command-id RunShellScript \
  --scripts "$SCRIPT_CONTENT" \
  --output json 2>&1) || {
    echo "ERROR: az vm run-command invoke failed for $VM_NAME"
    echo "$RESULT"
    exit 1
  }

# Print stdout from the run command
STDOUT=$(echo "$RESULT" | jq -r '.value[] | select(.code | contains("StdOut")) | .message' 2>/dev/null || echo "")
STDERR=$(echo "$RESULT" | jq -r '.value[] | select(.code | contains("StdErr")) | .message' 2>/dev/null || echo "")

if [ -n "$STDOUT" ]; then
  echo "--- stdout ---"
  echo "$STDOUT"
fi
if [ -n "$STDERR" ] && [ "$STDERR" != "" ]; then
  echo "--- stderr ---"
  echo "$STDERR"
fi

echo "$COMMENT — succeeded"
