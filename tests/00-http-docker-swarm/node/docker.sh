#!/bin/bash

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
	
  if true; then
    (
      cd /sys/fs/cgroup
      for sys in $(awk '!/^#/ { if ($4 == 1) print $1 }' /proc/cgroups); do
        mkdir -p $sys
	if ! mountpoint -q $sys; then
	  if ! mount -n -t cgroup -o $sys cgroup $sys; then
	    rmdir $sys || true
	  fi
	fi
      done
    )
  fi
  
  if ! mountpoint -q /sys/fs/cgroup/unified; then
    mkdir -p /sys/fs/cgroup/unified
    mount -t cgroup2 cgroup2 /sys/fs/cgroup/unified
  fi
}

cgroupfs_mount || true

ulimit -u unlimited

modprobe ip_vs

h=$(hostname)

while true; do dockerd >>/var/log/dockerd.log 2>&1; done &

echo "> ($h) Waiting for dockerd to start ..."
while ! docker ps >/dev/null 2>&1; do
  sleep 0.5
done

echo "> ($h) dockerd started"

node_state
echo "> ($h) docker swarm: node state = $NodeState; manager=$IsManager"

if [ "$NodeState" = "inactive" ] || [ "$NodeState" = "pending" ]; then

  if [ -f /swarm/worker ]; then
  
    while ! . /swarm/worker
    do
      sleep 0.5
    done
    
    echo "> ($h) Joined swarm!"
    
  else
    if docker swarm init >/dev/null; then
      docker swarm join-token worker | grep docker >/swarm/worker
      
      echo "> ($h) Initialised swarm!"
      
      echo "> ($h) Sleeping 10s to wait for other nodes  ..."
      sleep 10
      
      echo "> ($h) Listing nodes"
      docker node ls
      echo
      
      echo "> ($h) Creating 'http' service (please be patient) ..."
      # docker service create --name=nginx --mode=global -p 80:80 nginx
      docker service create --name=http --mode=global -p 80:80 \
        alpine ash -c 'apk update && apk add mini_httpd && mkdir -p /www && echo "<!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <title>hostname $HOSTNAME</title>
        </head>
        <body>
         Server is online
        </body>
        </html>" >/www/index.html && mini_httpd -d /www -D -l /dev/stdout'
      echo
      
      echo "> ($h) Itemising 'http' service ..."
      docker service ps http
      echo
      
      echo "> ($h) 'http' service launched"
    fi
  fi
fi

node_state
if [ "$NodeState" = "active" ] && [ "$IsManager" = "true" ]; then
  echo "> ($h) Now running: docker service logs -n 0 -f http"
  echo
  docker service logs -n 0 -f http
fi

echo "> ($h) Dropping to shell. Type CTRL+D to exit"
echo
bash -i
