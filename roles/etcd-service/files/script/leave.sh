#!/bin/bash
systemctl stop etcd

source /etc/etcd/etcd.conf

export ETCDCTL_API=3

memberID=$(ETCDCTL_API=3 etcdctl member list --endpoints=$ETCDCTL_ENDPOINTS|grep etcd$UNIQUESID|cut -d ',' -f 1 )

etcdctl member remove $memberID --endpoints=$ETCDCTL_ENDPOINTS
