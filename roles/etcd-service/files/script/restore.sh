#!/bin/bash

source /etc/etcd/etcd.conf

rm -fr $ETCD_DATA_DIR
mkdir -p $ETCD_DATA_DIR

ETCDCTL_API=3 etcdctl snapshot restore $ETCD_BACKUP_DIR/snapshot.db \
  --name etcd$UNIQUESID \
  --initial-cluster $ETCD_INITIAL_CLUSTER \
  --initial-cluster-token $ETCD_INITIAL_CLUSTER_TOKEN \
  --initial-advertise-peer-urls $ETCD_INITIAL_ADVERTISE_PEER_URLS \
  --data-dir="$ETCD_DATA_DIR"
