  #cloud-config
  password: ${netskope_gw_default_password}
  infiot:
    uri: ${netskope_tenant_url}
    token: ${netskope_gw_activation_key}
  runcmd:
  - |
    # Pin Azure IMDS route to primary NIC so the Netskope overlay (169.254.0.0/16)
    # cannot capture metadata traffic. The /32 host route wins by longest-prefix match.
    PRIMARY_NIC=$(ip -o link show | awk -F': ' '/^2:/{print $2}')
    ip route add 169.254.169.254/32 dev "$PRIMARY_NIC"

    # Make the IMDS route persistent across reboots
    cat > /etc/networkd-dispatcher/routable.d/50-imds-route <<'IMDS'
    #!/bin/bash
    PRIMARY_NIC=$(ip -o link show | awk -F': ' '/^2:/{print $2}')
    ip route replace 169.254.169.254/32 dev "$PRIMARY_NIC"
    IMDS
    chmod 755 /etc/networkd-dispatcher/routable.d/50-imds-route
  # NOTE: No SSM agent installation needed.
  # The Azure VM Agent is pre-installed in Azure Marketplace images and
  # enables Azure Run Command without any additional setup.
