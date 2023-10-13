#!/bin/bash

log() {
  echo "$1"
}

node_state() {
  NodeState=$(docker info --format '{{.Swarm.LocalNodeState}}')
  IsManager=$(docker info --format '{{.Swarm.ControlAvailable}}')
}

cgroupfs_mount() {
  # see also https://github.com/tianon/cgroupfs-mount/blob/master/cgroupfs-mount
  if grep -v '^#' /etc/fstab | grep -q cgroup \
    || [ ! -e /proc/cgroups ] \
    || [ ! -d /sys/fs/cgroup ]; then
      return
    fi
  
  if ! mountpoint -q /sys/fs/cgroup; then
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup
  fi
	
  cd /sys/fs/cgroup
  for sys in $(awk '!/^#/ { if ($4 == 1) print $1 }' /proc/cgroups); do
    mkdir -p $sys
    if ! mountpoint -q $sys; then
      if ! mount -n -t cgroup -o $sys cgroup $sys; then
        rmdir $sys || true
      fi
    fi
  done
  
  if ! mountpoint -q /sys/fs/cgroup/unified; then
    mkdir -p /sys/fs/cgroup/unified
    mount -t cgroup2 cgroup2 /sys/fs/cgroup/unified
  fi

  true
}

cgroupfs_mount

ulimit -u unlimited

modprobe ip_vs

h=$(hostname)

log "Checking network ..."
DOCKER_IF=$(ip -json route show | jq -j '.[] | select(.dst == "default") | .dev')
read -r DOCKER_IF_IP DOCKER_IF_MTU <<< \
  $(ip -json addr show eth0 | jq -j '.[0] | .addr_info[0].local, " ", .mtu')

log "- DOCKER_IF_IP=$DOCKER_IF_IP DOCKER_IF_MTU=$DOCKER_IF_MTU"

# Start dockerd and keep it running
log "Launching dockerd ..."
while true; do dockerd --mtu $DOCKER_IF_MTU >>/var/log/dockerd.log 2>&1; done &

for i in $(seq 1 10 | sort -nr)
do
  log "Waiting for dockerd to start (#$i) ..."
  docker ps >/dev/null 2>1 && break
  [ $i -eq 1 ] && exit 1
  sleep 0.5
done

log "dockerd started"

node_state
log "docker swarm: node state = $NodeState; manager=$IsManager"

log "Creating docker_gwbridge network with MTU $DOCKER_IF_MTU"
docker network create -d bridge \
   --subnet 172.18.0.0/16 \
   --opt com.docker.network.bridge.name=docker_gwbridge \
   --opt com.docker.network.bridge.enable_icc=false \
   --opt com.docker.network.bridge.enable_ip_masquerade=true \
   --opt com.docker.network.driver.mtu=$DOCKER_IF_MTU \
   docker_gwbridge

if [ "$NodeState" = "inactive" ] || [ "$NodeState" = "pending" ]; then

  if [ "$NODE" != "1" ]; then

    for i in $(seq 1 20 | sort -nr)
    do
      log "Waiting for swarm manager startup (#$i) ..."
      [ -f /swarm/worker ] && break
      [ $i -eq 1 ] && exit 1
      sleep 1
    done
  
    log "Swarm manager has started up."
    for i in $(seq 1 20 | sort -nr)
    do
      log "Joining swarm (#$i) ..."
      . /swarm/worker && break
      [ $i -eq 1 ] && exit 1
      sleep 0.5
    done
    
    log "Joined swarm!"
    
  else
  
    log "Initialising swarm ..."
    if ! docker swarm init >/dev/null; then
      log "Swarm initialisation FAILED!"
      exit 1
    fi

    log "Swarm initialised!"
    
    log "Removing default ingress ..."
    echo y | docker network rm ingress
    
    log "Creating new ingress with MTU $DOCKER_IF_MTU"
    docker network create \
    --driver=overlay \
    --ingress \
    --subnet=10.0.0.0/24 \
    --gateway=10.0.0.2 \
    --opt com.docker.network.driver.mtu=$DOCKER_IF_MTU \
    ingress
    
    log "Writing swarm 'join token' to shared storage and waiting for other nodes  ..."
    docker swarm join-token worker | grep docker >/swarm/worker

    for i in $(seq 1 30 | sort -nr)
    do
      nodes=$(docker node ls --format '{{json .}}' | wc -l)
      log "Waiting for remaining $((NODES-nodes)) of $NODES nodes to join swarm (#$i) ..."
      [ $nodes -eq $NODES ] && break
      [ $i -eq 1 ] && log "Swarm failed!" && exit 1
      sleep 1
    done

    log "Swarm nodes started:"
    docker node ls
    echo

    # Log this trigger line last.
    log "Swarm complete!"
        
  fi
fi

node_state
if [ "$NodeState" = "active" ] && [ "$IsManager" = "true" ]; then
  log "Manager ready"
fi

log "Looping indefinitely ..."
while true; do sleep infinity; done
