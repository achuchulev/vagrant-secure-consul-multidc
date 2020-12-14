# -*- mode: ruby -*-
# vi: set ft=ruby :

CONSUL_SERVER_COUNT = 3
CONSUL_CLIENT_COUNT = 1

DATACENTERS = {
  'dc1' => '172.16.1',
  'dc2' => '172.16.2'
}

vagrant_assets = File.dirname(__FILE__) + "/"

Vagrant.configure("2") do |config|
  # Define a vagrant box to use
  config.vm.box = "achuchulev/focal64base"
  config.vm.box_version = "0.0.1"

  # Set memory & CPU for Virtualbox
  config.vm.provider "virtualbox" do |vb|
    vb.memory = "512"
    vb.cpus = "1"
  end


  DATACENTERS.each.with_index() do |(dc, ip_range), index|

    (1..CONSUL_SERVER_COUNT).each do |i|
      config.vm.define vm_name="consul-server#{i}-#{dc}" do |consul_server|
       consul_server.vm.hostname = vm_name
       consul_server.vm.network "private_network", ip: "#{ip_range}" + ".#{10+i}"
       consul_server.vm.provision "shell", path: "#{vagrant_assets}/scripts/consul_server.sh", args: "#{i-1} #{dc} #{ip_range} #{CONSUL_SERVER_COUNT} #{index}", privileged: true
      end
    end

    (1..CONSUL_CLIENT_COUNT).each do |i|
      config.vm.define vm_name="consul-client#{i}-#{dc}" do |consul_client|
       consul_client.vm.hostname = vm_name
       consul_client.vm.network "private_network", ip: "#{ip_range}" + ".#{20+i}"
       consul_client.vm.provision "shell", path: "#{vagrant_assets}/scripts/consul_client.sh", args: "#{dc} #{i-1} #{ip_range} #{CONSUL_SERVER_COUNT}", privileged: true
       consul_client.vm.provision "shell", path: "#{vagrant_assets}/scripts/service_register.sh", args: "#{index}", privileged: true
      end
    end

  end
end
