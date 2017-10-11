#!/bin/bash

source /etc/etcd/etcd.conf

/usr/local/bin/etcdctl backup \
     --data-dir $ETCD_DATA_DIR \
     --backup-dir $ETCD_BACKUP_DIR
