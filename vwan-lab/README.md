# vWAN Lab — Phase 1: Virtual WAN Hub and Spokes

Deploys a Standard Virtual WAN, one virtual hub, and two spoke VNets with Ubuntu test VMs. Its outputs are consumed by Phase 2 (`../vwan-lab-nva/`). This workspace contains no Netskope resources.

See the [root README](../README.md) and [docs/](../docs/QUICKSTART.md) for architecture, full deployment instructions and verification.

## Quick Start

```sh
cp example.tfvars terraform.tfvars
# Edit: set location, resource_group_name, ssh_public_key_path, ssh_source_address

az login
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

> Hub provisioning takes 15–30 minutes. Do not cancel during hub creation.

After apply, capture the outputs for Phase 2:

```sh
terraform output virtual_hub_id
terraform output virtual_router_ips
terraform output virtual_router_asn
```

## Documentation

| Document | Description |
|---|---|
| [Quick Start](../docs/QUICKSTART.md) | Both phases end to end |
| [Deployment Guide](../docs/DEPLOYMENT_GUIDE.md#phase-1--vwan-labterraformtfvars) | Phase 1 variable reference |
| [Architecture](../docs/ARCHITECTURE.md) | Topology and resource inventory |
| [Phase 2: vwan-lab-nva](../vwan-lab-nva/README.md) | Netskope gateways attached to this hub |
