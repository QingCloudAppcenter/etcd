#!/bin/bash

source /etc/etcd/etcd.conf
mkdir -p $ETCD_BACKUP_DIR

ETCDCTL_API=3 /usr/local/bin/etcdctl snapshot save $ETCD_BACKUP_DIR/snapshot.db

index=0
while [ "$index" -lt $HOST_NUM ]
do
  hostIpname=HOST_$index
  rsync $ETCD_BACKUP_DIR/snapshot.db root@${!hostIpname}:$ETCD_BACKUP_DIR/snapshot.db
  index=$(($index + 1 ))
done
