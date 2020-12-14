#!/usr/bin/env bash

set -x

which curl wget unzip jq dig &>/dev/null || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install --no-install-recommends -y curl wget unzip jq dnsutils
}

IP=$(hostname -I | cut -f2 -d' ')
HOST=$(hostname)
server=$1
dc_name=$2
ip_range=$3
consul_server_count=$4
dc=$5

# latest consul release
CONSUL_VERSION=$(curl -sL https://releases.hashicorp.com/consul/index.json | jq -r '.versions[].version' | sort -V | egrep -v 'ent|beta|rc|alpha' | tail -n1)

# latest consul beta release
#CONSUL_VERSION=$(curl -sL https://releases.hashicorp.com/consul/index.json | jq -r '.versions[].version' | sort -V | grep -v 'ent|beta' | tail -n1)

which consul &>/dev/null || {
  echo Installing Consul version: ${CONSUL_VERSION}
  if [ -d /vagrant/pkg/ ]; then
    # check if consul file exist
    CHECKFILE="/vagrant/pkg/consul_${CONSUL_VERSION}_linux_amd64.zip"
    if [ ! -f "$CHECKFILE" ]; then
      pushd /vagrant/pkg
        rm -rf /vagrant/pkg/*
        wget https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip
      popd
    fi
  else
    mkdir /vagrant/pkg
    pushd /vagrant/pkg
      wget https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip
    popd
  fi
  pushd /usr/local/bin/
    unzip /vagrant/pkg/consul_${CONSUL_VERSION}_linux_amd64.zip 
    chown root:root consul
  popd
  consul -autocomplete-install
  complete -C /usr/local/bin/consul consul
  useradd --system --home /etc/consul.d --shell /bin/false consul
  mkdir --parents /opt/consul
  chown --recursive consul:consul /opt/consul
  cp /vagrant/conf/consul_server.service /etc/systemd/system/consul.service
  mkdir --parents /etc/consul.d/ssl
  
  # generate retry-join IP list
  SERVERS_IP_LIST=$( printf '"'$ip_range.%s'"\n' $(seq 11 1$consul_server_count))
  CONSUL_SERVER_IPS=`echo $SERVERS_IP_LIST  | tr ' ' ','`

  cat <<EOF > /etc/consul.d/consul.hcl
client_addr        = "0.0.0.0"
bind_addr          = "{{ GetInterfaceIP \"enp0s8\" }}"
data_dir           = "/opt/consul"
datacenter         = "$dc_name"
log_level          = "INFO"
server             = true
ui                 = true
retry_join         = [$CONSUL_SERVER_IPS]

auto_encrypt = {
  allow_tls = true
}

autopilot = {
  cleanup_dead_servers       = true,
  last_contact_threshold     = "200ms",
  max_trailing_logs          = 250,
  server_stabilization_time  = "10s",
}
node_meta = { },

connect = {
  enabled = true
}
EOF
  
  # check if we create the first server && dc
  if [[ $dc == 0 ]]; then
    cat <<EOF > /etc/consul.d/acl.hcl
"acl" = {
  "default_policy" = "deny"
  "down_policy" = "extend-cache"
  "enable_token_persistence" = true
  "enabled" = true
}
"primary_datacenter" = "$dc_name"
EOF
    if [[ $server == 0 ]]; then
      # write the IPs of primary DC for wan_join
      echo $CONSUL_SERVER_IPS > /vagrant/conf/wan_join.txt

      # write primary dc name
      echo $dc_name > /vagrant/conf/primary_dc.txt

      # cleanup of previous deployments
      if [ -d /vagrant/ssl/ ]; then
        rm -rf /vagrant/ssl/*
      else
      mkdir -p /vagrant/ssl/
      fi
      # end cleanup

      # bootstrap ACL config
      cat <<EOF > /etc/consul.d/bootstrap.hcl
"bootstrap" = true
EOF
    # create Consul CA & CLI certificate
    pushd /vagrant/ssl/ 
      consul tls ca create
      # generate a CLI certificate for HTTPS to access the API, including using any of the CLI commands.
      consul tls cert create -cli -additional-ipaddress="127.0.0.1" #-dc="$dc_name" 
      crypto=`consul keygen`
      cat <<EOF > gossip.hcl
"encrypt" = "${crypto}"
EOF
    popd
    fi
  else
    if [[ $server == 0 ]]; then
      # bootstrap ACL config
      cat <<EOF > /etc/consul.d/bootstrap.hcl
"bootstrap" = true
EOF
    fi
    PRIMARY_DC=`cat /vagrant/conf/primary_dc.txt`
    PRIMARY_DC_WAN_IPS=`cat /vagrant/conf/wan_join.txt`
    cat <<EOF > /etc/consul.d/acl.hcl
"primary_datacenter" = "$PRIMARY_DC"
"retry_join_wan" = [$PRIMARY_DC_WAN_IPS]
"acl" = {
  "default_policy" = "deny"
  "down_policy" = "extend-cache"
  "enable_token_persistence" = true
  "enable_token_replication" = true
  "enabled" = true
}
EOF
  fi
  pushd /vagrant/ssl/
    cp consul-agent-ca.pem /etc/consul.d/ssl/
    cp gossip.hcl /etc/consul.d/
    cp *-cli-consul-0*.pem /etc/consul.d/ssl/
    consul tls cert create -server -dc="$dc_name" -additional-ipaddress="$IP" -additional-dnsname="$HOST" 
    cp $dc_name-server-consul-$server-key.pem /etc/consul.d/ssl/$dc_name-server-consul-$server-key.pem
    cp $dc_name-server-consul-$server.pem /etc/consul.d/ssl/$dc_name-server-consul-$server.pem
  popd

  cat <<EOF > /etc/consul.d/rpc.hcl
"verify_incoming_https" = false
"verify_incoming_rpc" = true
"verify_outgoing" = true
"verify_server_hostname" = true
"ca_file" = "/etc/consul.d/ssl/consul-agent-ca.pem"
"cert_file" = "/etc/consul.d/ssl/$dc_name-server-consul-$server.pem"
"key_file" = "/etc/consul.d/ssl/$dc_name-server-consul-$server-key.pem"
"ports" = {
  "http" = -1
  "https" = 8501
}
EOF

  chown --recursive consul:consul /etc/consul.d
  chmod 640 /etc/consul.d/consul.hcl
  systemctl enable consul
  systemctl start consul
  sleep 5
  

  # Bootstraping ACL on primary dc only
  export CONSUL_HTTP_ADDR=https://127.0.0.1:8501
  export CONSUL_CACERT=/etc/consul.d/ssl/consul-agent-ca.pem

  if [[ $dc == 0 ]]; then
    if [[ $server == 0 ]]; then
      # cleanup of previous ACL deployments
      if [ -d /vagrant/token/ ]; then
        rm -rf /vagrant/token/*
      else
        mkdir -p /vagrant/token
      fi
      # end cleanup

      consul acl bootstrap | grep "SecretID:" | cut -c15- | tr -d '[:space:]' > /vagrant/token/consul-master-token.txt

      export CONSUL_HTTP_TOKEN=`cat /vagrant/token/consul-master-token.txt` # bootstrap token

      # Servers ACL token
      cat <<EOF > consul-servers-policy.hcl
node_prefix "consul-server" {
policy = "write"
}
EOF
      consul acl policy create -name consul-servers -rules @consul-servers-policy.hcl
      consul acl token create -description "consul servers agent token" -policy-name consul-servers | grep "SecretID:" | cut -c15- | tr -d '[:space:]' > /vagrant/token/consul-servers.txt


      # Clients ACL token
      cat <<EOF > consul-clients-policy.hcl
node_prefix "consul-client" {
  policy = "write"
}
EOF
      consul acl policy create -name "consul-clients" -rules @consul-clients-policy.hcl
      consul acl token create -description "consul clients agent token" -policy-name consul-clients | grep "SecretID:" | cut -c15- | tr -d '[:space:]' > /vagrant/token/consul-clients.txt
  
      # Replication ACL token
      cat <<EOF > consul-replication-policy.hcl
acl = "write"

operator = "write"

service_prefix "" {
  policy = "read"
  intentions = "read"
}
EOF

      consul acl policy create -name "replication" -rules @consul-replication-policy.hcl
      consul acl token create -description "consul replication token" -policy-name replication | grep "SecretID:" | cut -c15- | tr -d '[:space:]' > /vagrant/token/consul-replication-token.txt
    
      TOKEN=`cat /vagrant/token/consul-servers.txt`
      consul acl set-agent-token agent "$TOKEN"
    
    # DNS request token
    cat <<EOF > dns-request-policy.hcl
  ## dns-request-policy.hcl

node_prefix "" {
  policy = "read"
}
service_prefix "" {
  policy = "read"
}

# only needed if using prepared queries
query_prefix "" {
  policy = "read"
}
EOF
      consul acl policy create -name "dns-requests" -rules @dns-request-policy.hcl
      consul acl token create -description "Token for DNS Requests" -policy-name dns-requests | grep "SecretID:" | cut -c15- | tr -d '[:space:]' > /vagrant/token/dns-requests-token.txt
      DNS_TOKEN=`cat /vagrant/token/dns-requests-token.txt`
      consul acl set-agent-token default "$DNS_TOKEN"
    else
      export CONSUL_HTTP_TOKEN=`cat /vagrant/token/consul-master-token.txt` # bootstrap token
      TOKEN=`cat /vagrant/token/consul-servers.txt`
      consul acl set-agent-token agent "$TOKEN"
      DNS_TOKEN=`cat /vagrant/token/dns-requests-token.txt`
      consul acl set-agent-token default "$DNS_TOKEN"
    fi
  else
    export CONSUL_HTTP_TOKEN=`cat /vagrant/token/consul-master-token.txt` # bootstrap token
    REPLICATION_TOKEN=`cat /vagrant/token/consul-replication-token.txt`
    consul acl set-agent-token replication "$REPLICATION_TOKEN"
    DNS_TOKEN=`cat /vagrant/token/dns-requests-token.txt`
    consul acl set-agent-token default "$DNS_TOKEN"
  fi

  # Forward DNS for Consul Service Discovery
  # systemd-resolved setup
  echo -e "DNS=127.0.0.1 \nDomains=~consul" >> /etc/systemd/resolved.conf
  iptables -t nat -A OUTPUT -d localhost -p udp -m udp --dport 53 -j REDIRECT --to-ports 8600
  iptables -t nat -A OUTPUT -d localhost -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 8600
  service systemd-resolved restart
  
}
