#!/usr/bin/env bash
echo "==> Nomad (server)"

echo "--> Fetching"

install_from_url "nomad" "${nomad_url}"
sleep 10


echo "--> Generating Vault token..."
export VAULT_TOKEN="$(consul kv get service/vault/root-token)"
  NOMAD_VAULT_TOKEN="$(VAULT_TOKEN="$VAULT_TOKEN" \
  VAULT_ADDR="https://vault.query.consul:8200" \
  VAULT_SKIP_VERIFY=true \
  vault token create -field=token -policy=superuser -policy=nomad-server -display-name=${node_name} -id=${node_name} -period=72h)"

consul kv put service/vault/${node_name}-token $NOMAD_VAULT_TOKEN

echo "--> Create a Directory to Use as a Mount Target"
sudo mkdir -p /opt/mysql/data/
sudo mkdir -p /opt/mongodb/data/
sudo mkdir -p /opt/prometheus/data/

echo "--> Installing CNI plugin"
sudo mkdir -p /opt/cni/bin/
wget -O cni.tgz ${cni_plugin_url}
sudo tar -xzf cni.tgz -C /opt/cni/bin/


echo "--> Writing configuration"
sudo mkdir -p /mnt/nomad
sudo mkdir -p /etc/nomad.d
sudo tee /etc/nomad.d/config.hcl > /dev/null <<EOF
name         = "${node_name}"
data_dir     = "/mnt/nomad"
enable_debug = true
"bind_addr" = "0.0.0.0"
datacenter = "${location}"
region = "global"
advertise {
  http = "${public_ip}:4646"
  rpc  = "${public_ip}:4647"
  serf = "${public_ip}:4648"
}
server {
  enabled          = true
  bootstrap_expect = ${nomad_servers}
  encrypt          = "${nomad_gossip_key}"
}
client {
  enabled = true
   options {
    "driver.raw_exec.enable" = "1"
  }
   meta {
    "type" = "server"
    "name" = "${node_name}"
  }
  host_volume "mysql_mount" {
    path      = "/opt/mysql/data/"
    read_only = false
  }
  host_volume "mongodb_mount" {
    path      = "/opt/mongodb/data/"
    read_only = false
  }
  host_volume "prometheus_mount" {
    path      = "/opt/prometheus/data/"
    read_only = false
  }
}
tls {
  rpc  = true
  http = true
  ca_file   = "/usr/local/share/ca-certificates/01-me.crt"
  cert_file = "/etc/ssl/certs/me.crt"
  key_file  = "/etc/ssl/certs/me.key"
  verify_server_hostname = false
}
consul {
    address = "localhost:8500"
    server_service_name = "nomad-server"
    client_service_name = "nomad-client"
    auto_advertise = true
    server_auto_join = true
    client_auto_join = true
}
vault {
  enabled          = true
  address          = "https://active.vault.service.consul:8200"
  ca_file          = "/usr/local/share/ca-certificates/01-me.crt"
  cert_file        = "/etc/ssl/certs/me.crt"
  key_file         = "/etc/ssl/certs/me.key"
  create_from_role = "nomad-cluster"
  tls_skip_verify = "true"
}

autopilot {
    cleanup_dead_servers = true
    last_contact_threshold = "200ms"
    max_trailing_logs = 250
    server_stabilization_time = "10s"
    enable_redundancy_zones = false
    disable_upgrade_migration = false
    enable_custom_upgrades = false
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics = true
  prometheus_metrics = true
}
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/nomad.sh > /dev/null <<"EOF"
alias noamd="nomad"
alias nomas="nomad"
alias nomda="nomad"
export NOMAD_ADDR="https://${node_name}.node.consul:4646"
export NOMAD_CACERT="/usr/local/share/ca-certificates/01-me.crt"
export NOMAD_CLIENT_CERT="/etc/ssl/certs/me.crt"
export NOMAD_CLIENT_KEY="/etc/ssl/certs/me.key"
EOF
source /etc/profile.d/nomad.sh

echo "--> Generating systemd configuration"
sudo tee /etc/systemd/system/nomad.service > /dev/null <<EOF
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs/
Requires=network-online.target
After=network-online.target

[Service]
Environment=VAULT_TOKEN=$NOMAD_VAULT_TOKEN
ExecStart=/usr/local/bin/nomad agent -config="/etc/nomad.d"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable nomad
sudo systemctl start nomad
sleep 2

echo "--> Waiting for all Nomad servers"
while [ "$(nomad server members 2>&1 | grep "alive" | wc -l)" -lt "${nomad_servers}" ]; do
  sleep 5
done

echo "--> Waiting for Nomad leader"
while [ -z "$(curl -s http://${node_name}.node.consul:4646/v1/status/leader)" ]; do
  sleep 5
done

echo "==> Nomad is done!"
