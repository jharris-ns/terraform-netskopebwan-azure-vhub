# vWAN Lab — Phase 2: Netskope SD-WAN NVA

Deploys Netskope BWAN gateway VMs in a spoke VNet attached to the Phase 1 vWAN hub, with eBGP peering to the hub's built-in router. Manages the full lifecycle: NVA spoke VNet, hub BGP connections, Netskope portal configuration, VM provisioning, FRR/BGP config, and SSE monitor.

Consumes the outputs of Phase 1 (`../vwan-lab/`).

See the [root README](../README.md) and [docs/](../docs/QUICKSTART.md) for architecture, full deployment instructions and verification.

## Quick Start

```sh
cp example.tfvars terraform.tfvars
# Edit: set virtual_hub_id, virtual_router_ips (from Phase 1 output), gateway_policy

export TF_VAR_netskope_tenant_url='your-tenant.infiot.net'
export TF_VAR_netskope_tenant_token='YOUR_API_TOKEN'
export TF_VAR_admin_password='YourOsPassword123!'   # single quotes avoid zsh ! expansion

az login
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Verify

```sh
terraform output bgp_verify_commands
```

Expected: both hub router IPs and both Netskope overlay peers `Established`; exactly `0.0.0.0/0` (MED 10) advertised to each hub peer. See [Operations — BGP Verification](../docs/OPERATIONS.md#checking-bgp-health).

## Re-Running Configuration

```sh
# Force BGP config re-run after run_command.tf changes
terraform apply -replace='null_resource.bgp_config["ntsk-gw-1"]' -var-file=terraform.tfvars

# Force SSE monitor re-deploy
terraform apply -replace='null_resource.sse_monitor["ntsk-gw-1"]' -var-file=terraform.tfvars
```

## Documentation

| Document | Description |
|---|---|
| [Quick Start](../docs/QUICKSTART.md) | Both phases end to end |
| [Deployment Guide](../docs/DEPLOYMENT_GUIDE.md#phase-2--vwan-lab-nvaterraformtfvars) | Phase 2 variable reference |
| [Operations](../docs/OPERATIONS.md) | Re-runs, gateway replacement, hub redeploy |
| [Troubleshooting](../docs/TROUBLESHOOTING.md) | Diagnostic flowchart and known limitations |
| [DevOps Notes](../docs/DEVOPS_NOTES.md) | Run Command and SSE monitor internals |
| [Phase 1: vwan-lab](../vwan-lab/README.md) | The hub this workspace peers with |
