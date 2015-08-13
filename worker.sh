#!/bin/bash

# Copyright 2015 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A scripts to install k8s worker node.
# Author @wizard_cxy @reouser

set -e

# Make sure docker daemon is running
if ( ! ps -ef | grep "/usr/bin/docker" | grep -v 'grep' &> /dev/null  ); then
    echo "Docker is not running on this machine!"
    exit 1
fi

# Run as root
if [ "$(id -u)" != "0" ]; then
    echo >&2 "Please run as root"
    exit 1
fi

# Make sure master ip is properly set
if [ -z ${MASTER_IP} ]; then
    echo "Please export MASTER_IP in your env"
    exit 1
else
    echo "k8s master is set to: ${MASTER_IP}"
fi

# Check if a command is valid
command_exists() {
    command -v "$@" > /dev/null 2>&1
}


# Start the bootstrap daemon
bootstrap_daemon() {
    sudo -b docker -d -H unix:///var/run/docker-bootstrap.sock -p /var/run/docker-bootstrap.pid --iptables=false --ip-masq=false --bridge=none --graph=/var/lib/docker-bootstrap 2> /var/log/docker-bootstrap.log 1> /dev/null

    sleep 5
}

DOCKER_CONF=""

# Start k8s components in containers
start_k8s() {
    # Start flannel
    flannelCID=$(sudo docker -H unix:///var/run/docker-bootstrap.sock run -d --restart=always --net=host --privileged -v /dev/net:/dev/net andrewpsuedonym/flanneld flanneld --etcd-endpoints=http://${MASTER_IP}:4001 -iface="eth0")

    sleep 8

    # Copy flannel env out and source it on the host
    sudo docker -H unix:///var/run/docker-bootstrap.sock cp ${flannelCID}:/run/flannel/subnet.env .
    source subnet.env

    DOCKER_CONF="/usr/lib/systemd/system/docker.service"

    if grep "mtu=" $DOCKER_CONF
    then
    sed "s|--mtu=[0-9]\+|--mtu=${FLANNEL_MTU}|" $DOCKER_CONF -i && sed "s|--bip=[0-9./]\+|--bip=${FLANNEL_SUBNET}|" $DOCKER_CONF -i
    else
    sed "s|ExecStart=/usr/bin/docker|ExecStart=/usr/bin/docker --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}|" $DOCKER_CONF -i
    fi


    ifconfig docker0 down
    brctl delbr docker0
    systemctl daemon-reload 
    systemctl start docker
    

    # sleep a little bit
    sleep 5
    
    # Start kubelet & proxy in container
    sudo docker run --net=host --privileged -d -v /sys:/sys:ro -v /var/run/docker.sock:/var/run/docker.sock  andrewpsuedonym/hyperkube hyperkube kubelet --api-servers=http://${MASTER_IP}:8080 --v=2 --address=0.0.0.0 --enable-server --hostname-override=$(hostname -i) --pod-infra-container-image=andrewpsuedonym/pause
    sudo docker run -d --net=host --privileged andrewpsuedonym/hyperkube hyperkube proxy --master=http://${MASTER_IP}:8080 --v=2

}
echo "Worker set up script by Jim Walker"
echo "Adapted from google's docker-multinode/worker.sh"
echo
echo "For use with Arch Linux | ARM only"


echo "Starting bootstrap docker ..."
bootstrap_daemon

echo "Starting k8s ..."
start_k8s

echo "Worker done!"
