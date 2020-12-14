#!/usr/bin/env bash
set -x
dc_index=$1

export DEBIAN_FRONTEND=noninteractive
export HOST=$(hostname)
IP=$(hostname -I | cut -f2 -d' ')
export CONSUL_CACERT=/etc/consul.d/ssl/consul-agent-ca.pem
export CONSUL_CLIENT_CERT=/vagrant/ssl/dc1-cli-consul-0.pem
export CONSUL_CLIENT_KEY=/vagrant/ssl/dc1-cli-consul-0-key.pem
export CONSUL_HTTP_TOKEN=`cat /vagrant/token/consul-master-token.txt` # bootstrap token
export CONSUL_HTTP_ADDR=https://127.0.0.1:8501

echo "Registering Services..."
#####################
# Download services #
#####################
if [ -d /vagrant/services/ ]; then
  # check if counting service file exist.
  CHECKFILE1="/vagrant/services/counting-service_linux_amd64"
  CHECKFILE2="/vagrant/services/dashboard-service_linux_amd64"
  if [ ! -f "$CHECKFILE1" ]; then
    pushd /vagrant/services
      wget https://github.com/hashicorp/demo-consul-101/releases/download/0.0.3/counting-service_linux_amd64.zip
      unzip ./counting-service_linux_amd64.zip
      rm -rf counting-service_linux_amd64.zip
    popd
  fi
  # check if dashboard service file exist.
  if [ ! -f "$CHECKFILE2" ]; then
    pushd /vagrant/services
      wget https://github.com/hashicorp/demo-consul-101/releases/download/0.0.3/dashboard-service_linux_amd64.zip
      unzip ./dashboard-service_linux_amd64.zip
      rm -rf dashboard-service_linux_amd64.zip
    popd
  fi
else
  sudo mkdir -p /vagrant/services
  pushd /vagrant/services
    wget https://github.com/hashicorp/demo-consul-101/releases/download/0.0.3/counting-service_linux_amd64.zip
    wget https://github.com/hashicorp/demo-consul-101/releases/download/0.0.3/dashboard-service_linux_amd64.zip
    unzip ./counting-service_linux_amd64.zip
    unzip ./dashboard-service_linux_amd64.zip
    rm -rf counting-service_linux_amd64.zip
    rm -rf dashboard-service_linux_amd64.zip
  popd
fi

if [[ $dc_index == 0 ]]; then
  cat <<EOF > dashboard-service-policy.hcl
service "dashboard" {
  policy = "write"
}
EOF

  consul acl policy create -name dashboard-service -rules @dashboard-service-policy.hcl
  DASHBOARD_TOKEN=`consul acl token create -description "Token for Dashboard Service" -policy-name dashboard-service | grep "SecretID:" | cut -c15- | tr -d '[:space:]'`

   cat <<EOF > counting-service-policy.hcl
service "counting" {
  policy = "write"
}
EOF

  consul acl policy create -name counting-service -rules @counting-service-policy.hcl
  COUNTING_TOKEN=`consul acl token create -description "Token for Counting Service" -policy-name counting-service | grep "SecretID:" | cut -c15- | tr -d '[:space:]'`

fi

cat <<EOF > /etc/consul.d/counting.hcl
service {
  name = "counting"
  id = "counting-1"
  port = 9003
  token = "$COUNTING_TOKEN"
  connect {
    sidecar_service {}
  }
  check {
    id       = "counting-check"
    http     = "http://localhost:9003/health"
    method   = "GET"
    interval = "1s"
    timeout  = "1s"
  }
}
EOF

cat <<EOF > /etc/consul.d/dashboard.hcl
service {
  name = "dashboard"
  port = 9002
  token = "$DASHBOARD_TOKEN"
  connect {
    sidecar_service {
      proxy {
        upstreams = [
          {
            destination_name = "counting"
            local_bind_port  = 5000
          }
        ]
      }
    }
  }
  check {
    id       = "dashboard-check"
    http     = "http://localhost:9002/health"
    method   = "GET"
    interval = "1s"
    timeout  = "1s"
  }
}
EOF

sleep 10

#### Register counting & dashboard services
consul services register /etc/consul.d/counting.hcl
consul services register /etc/consul.d/dashboard.hcl

#### Create intention
if [[ $dc_index == 0 ]]; then
consul intention create dashboard counting
sleep 5
fi

#### Start the counting & dashboard services
PORT=9002 COUNTING_SERVICE_URL="http://localhost:5000" /vagrant/services/dashboard-service_linux_amd64 &> ./dashboard_$HOST.log &
sleep 5
PORT=9003 /vagrant/services/counting-service_linux_amd64 &> ./counting_$HOST.log &
sleep 5

#### Start the built-in sidecar proxy for the counting & dashboard services
consul connect proxy -sidecar-for counting-1 > counting-proxy_$HOST.log &
sleep 5
consul connect proxy -sidecar-for dashboard > dashboard-proxy_$HOST.log &
sleep 2
set +x

echo "Count Dashboard http://$IP:9002"
