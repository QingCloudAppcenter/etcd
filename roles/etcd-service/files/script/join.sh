#!/bin/bash

source /etc/etcd/etcd.conf

ETCDCTL_API=3

etcdctl member add etcd-$UNIQUESID $ETCD_LISTEN_PEER_URLS
mkdir -p $ETCD_DATA_DIR

systemctl start etcd
