#!/bin/bash

if [[ $( ETCDCTL_API=3 etcdctl endpoint health --endpoints=$ETCDCTL_ENDPOINTS) ]]
then
source /etc/etcd/etcd.conf
ETCDCTL_API=3 etcdctl lock clusterlock join.sh
else
/usr/local/bin/etcd --name=etcd$UNIQUESID
fi
