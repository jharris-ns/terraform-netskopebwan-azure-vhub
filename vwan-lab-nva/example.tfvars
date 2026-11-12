#------------------------------------------------------------------------------
#  Example variable values for vwan-lab-nva (Phase 2).
#  Safe to commit — no secrets. Copy to terraform.tfvars and fill in:
#    - gateway_policy
#    - Set secrets via environment variables (see below)
#
#  Secrets — set via environment variables, never in terraform.tfvars:
#    export TF_VAR_netskope_tenant_url="your-tenant.infiot.net"
#    export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
#    export TF_VAR_admin_password="YourOsPassword123!"
#    export TF_VAR_gateway_password="YourGwPassword123!"
#------------------------------------------------------------------------------

# Phase 1 vhub outputs — copy from: cd ../vwan-lab && terraform output
virtual_hub_id      = "/subscriptions/REPLACE/resourceGroups/rg-ntsk-gw/providers/Microsoft.Network/virtualHubs/vhub-ntsk-gw-westeurope-01"
virtual_router_ips  = ["10.0.0.70", "10.0.0.69"]
virtual_router_asn  = 65515
vhub_address_prefix = "10.0.0.0/24"

# Resource group and location (must match Phase 1)
resource_group_name = "rg-ntsk-gw"
location            = "westeurope"

# NVA spoke network
# Subnet CIDRs are auto-carved from nva_spoke_address_space using subnet_size.
# Must not overlap hub (10.0.0.0/24) or Phase 1 spokes (10.1-2.0.0/24).
nva_spoke_address_space = "10.3.0.0/24"
# subnet_size = 28  # /28 per interface (default); 2 subnets × gateway_count must fit

# Gateway scaling
# gateway_prefix-1, gateway_prefix-2, ... are the gateway keys used in all resource names.
gateway_count  = 2
gateway_prefix = "ntsk-gw"

# VM — Standard_DS11_v2 is Gen1-compatible; check zone availability before changing size:
#   az vm list-skus --location westeurope --size Standard_DS11 --zone true -o table
vm_size     = "Standard_DS11_v2"
accept_plan = false   # set true if Marketplace terms not pre-accepted

# Netskope portal
gateway_bgp_asn = 400   # must not be 65515 (reserved by vhub router)
gateway_policy  = "REPLACE-WITH-YOUR-POLICY-NAME"
gateway_role    = "hub"
