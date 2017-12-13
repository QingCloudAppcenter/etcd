#!/bin/bash

source /etc/etcd/etcd.conf
index=0
while [ "$index" -lt $DELETING_HOST_NUM ]
do
  hostIpname=DELETING_HOST_$index
  memberID=$(ETCDCTL_API=3 /usr/local/bin/etcdctl member list |grep ${!hostIpname}|cut -d ',' -f 1 )
  ETCDCTL_API=3 /usr/local/bin/etcdctl member remove $memberID
  index=$(($index + 1 ))
done
