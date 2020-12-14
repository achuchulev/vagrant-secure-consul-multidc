#!/usr/bin/env bash

HOST=$(hostname)
dc_name=$1
client_index=$2
ip_range=$3
consul_server_count=$4

set -x

which curl wget unzip jq dig &>/dev/null || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install --no-install-recommends -y curl wget unzip jq dnsutils
}

CONSUL_VERSION=$(curl -sL https://releases.hashicorp.com/consul/index.json | jq -r '.versions[].version' | sort -V | egrep -v 'ent|beta|rc|alpha' | tail -n1)

#beta version
#CONSUL_VERSION=$(curl -sL https://releases.hashicorp.com/consul/index.json | jq -r '.versions[].version' | sort -V | grep -v 'ent|beta' | tail -n1)

which consul &>/dev/null || {
  echo Installing Consul version: ${CONSUL_VERSION}
  pushd /usr/local/bin/
    unzip /vagrant/pkg/consul_${CONSUL_VERSION}_linux_amd64.zip 
    chown root:root consul
  popd
  consul -autocomplete-install
  complete -C /usr/local/bin/consul consul
  useradd --system --home /etc/consul.d --shell /bin/false consul
  mkdir --parents /opt/consul
  chown --recursive consul:consul /opt/consul
  cp /vagrant/conf/consul_client.service /etc/systemd/system/consul.service
  mkdir --parents /etc/consul.d/ssl
  cp /vagrant/ssl/consul-agent-ca.pem /etc/consul.d/ssl/
  cp /vagrant/ssl/gossip.hcl /etc/consul.d/
  chown --recursive consul:consul /etc/consul.d

  # !!! Check for stale cert files and perform clean up
  if [ ! -f "/vagrant/ssl/$dc_name-client-consul-$client_index*.pem" ]; then
    rm -rf /vagrant/ssl/$dc_name-client-consul-$client_index*.pem
  fi

  pushd /vagrant/ssl/
    consul tls cert create -client -dc="$dc_name"
  popd
  
  cp /vagrant/ssl/$dc_name-client-consul-$client_index*.pem /etc/consul.d/ssl/

  # generate retry-join IP list
  SERVERS_IP_LIST=$( printf '"'$ip_range.%s'"\n' $(seq 11 1$consul_server_count))
  CONSUL_SERVER_IPS=`echo $SERVERS_IP_LIST  | tr ' ' ','`

  cat <<EOF > /etc/consul.d/consul.hcl
client_addr        = "127.0.0.1"
bind_addr          = "{{ GetInterfaceIP \"enp0s8\" }}"
data_dir           = "/opt/consul"
datacenter         = "$dc_name"
log_level          = "DEBUG"
server             = false
enable_syslog      = true
retry_join         = [$CONSUL_SERVER_IPS]

auto_encrypt = {
  tls = true
}
EOF

  cat <<EOF > /etc/consul.d/rpc.hcl
"verify_incoming" = true
"verify_outgoing" = true
"verify_server_hostname" = true
"ca_file" = "/etc/consul.d/ssl/consul-agent-ca.pem"
"cert_file" = "/etc/consul.d/ssl/$dc_name-client-consul-$client_index.pem"
"key_file" = "/etc/consul.d/ssl/$dc_name-client-consul-$client_index-key.pem"
"ports" = {
  "http" = -1
  "https" = 8501
}
EOF

  TOKEN=`cat /vagrant/token/consul-clients.txt`
  DNS_TOKEN=`cat /vagrant/token/dns-requests-token.txt`
  cat <<EOF > /etc/consul.d/acl.hcl
"acl" = {
  "default_policy" = "deny"
  "enable_token_persistence" = true
  "enabled" = true

  "tokens" = {
    "agent" = "$TOKEN"
    "default" = "$DNS_TOKEN"
  }
}
EOF

  systemctl enable consul
  systemctl start consul
  systemctl status consul

  # Forward DNS for Consul Service Discovery
  # systemd-resolved setup
  echo -e "DNS=127.0.0.1 \nDomains=~consul" >> /etc/systemd/resolved.conf
  iptables -t nat -A OUTPUT -d localhost -p udp -m udp --dport 53 -j REDIRECT --to-ports 8600
  iptables -t nat -A OUTPUT -d localhost -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 8600
  service systemd-resolved restart
  
}
