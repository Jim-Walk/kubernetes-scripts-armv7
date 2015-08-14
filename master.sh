#!/bin/bash

set -e

# Make sure docker daemon is running
if ( ! ps -ef | grep "/usr/bin/docker" | grep -v 'grep' &> /dev/null ); then
    echo "Docker is not running on this machine!"
    exit 1
fi

# Make sure k8s version env is properly set

# Run as root
if [ "$(id -u)" != "0" ]; then
    echo >&2 "Please run as root"
    exit 1
fi

# Check if a command is valid
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Start the bootstrap daemon
bootstrap_daemon() {
    
    sh -c 'docker -d -H unix:///var/run/docker-bootstrap.sock -p /var/run/docker-bootstrap.pid --iptables=false --ip-masq=false --bridge=none --graph=/var/lib/docker-bootstrap 2> /var/log/docker-bootstrap.log 1> /dev/null &'
    #this can fail
    docker -H unix:///var/run/docker-bootstrap.sock rm -f $(docker -H unix:///var/run/docker-bootstrap.sock ps -aq) >/dev/null || true
    #sh -c 'docker -d -H unix:///var/run/docker-bootstrap.sock -p /var/run/docker-bootstrap.pid --iptables=false --ip-masq=false --bridge=none --graph=/var/lib/docker-bootstrap 2> /var/log/docker-bootstrap.log 1> /dev/null'
    sleep 5
}

# Start k8s components in containers
DOCKER_CONF=""

start_k8s(){
    # Start etcd 
    docker -H unix:///var/run/docker-bootstrap.sock run --restart=always --net=host -d andrewpsuedonym/etcd:2.1.1 /bin/etcd --addr=127.0.0.1:4001 --bind-addr=0.0.0.0:4001 --data-dir=/var/etcd/data

    sleep 5
    # Set flannel net config
    docker -H unix:///var/run/docker-bootstrap.sock run --net=host andrewpsuedonym/etcd:2.1.1 etcdctl set /coreos.com/network/config '{ "Network": "10.1.0.0/16", "Backend": {"Type": "vxlan"}}'

    # iface may change to a private network interface, eth0 is for default
    flannelCID=$(docker -H unix:///var/run/docker-bootstrap.sock run --restart=always -d --net=host --privileged -v /dev/net:/dev/net andrewpsuedonym/flanneld flanneld)

    sleep 8

    # Copy flannel env out and source it on the host
    docker -H unix:///var/run/docker-bootstrap.sock cp ${flannelCID}:/run/flannel/subnet.env .
    source /root/subnet.env

    DOCKER_CONF=/usr/lib/systemd/system/docker.service

    if grep "mtu=" $DOCKER_CONF
    then
    sed "s|--mtu=[0-9]\+|--mtu=${FLANNEL_MTU}|" $DOCKER_CONF -i && sed "s|--bip=[0-9./]\+|--bip=${FLANNEL_SUBNET}|" $DOCKER_CONF -i
    else
    sed "s|ExecStart=/usr/bin/docker|ExecStart=/usr/bin/docker --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}|" $DOCKER_CONF -i
    fi

    ifconfig docker0 down

    brctl delbr docker0 
    systemctl daemon-reload
    systemctl restart docker

    # sleep a little bit
    sleep 5

    # Start kubelet & proxy, then start master components as pods
    docker run --net=host --privileged -d -v /sys:/sys:ro -v /var/run/docker.sock:/var/run/docker.sock  andrewpsuedonym/hyperkube hyperkube kubelet --api-servers=http://localhost:8080 --v=2 --address=0.0.0.0 --enable-server --hostname-override=127.0.0.1 --config=/etc/kubernetes/manifests-multi --pod-infra-container-image=andrewpsuedonym/pause
    docker run -d --net=host --privileged andrewpsuedonym/hyperkube hyperkube proxy --master=http://127.0.0.1:8080 --v=2   
}

echo "Worker set up script by Jim Walker"
echo "Adapted from google's docker-multinode/worker.sh"
echo
echo "For use with Arch Linux | ARM only"
echo "This script must be run from the /root/ directory"



echo "Starting bootstrap docker ..."
bootstrap_daemon

echo "Starting k8s ..."
start_k8s

echo "Master done!"
