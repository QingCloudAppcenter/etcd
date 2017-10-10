#!/bin/bash

source /etc/etcd/etcd.conf


memberID=$(ETCDCTL_API=3 /usr/local/bin/etcdctl member list --endpoints=$ETCDCTL_ENDPOINTS|grep etcd$UNIQUESID|cut -d ',' -f 1 )

ETCDCTL_API=3 /usr/local/bin/etcdctl member remove $memberID --endpoints=$ETCDCTL_ENDPOINTS
