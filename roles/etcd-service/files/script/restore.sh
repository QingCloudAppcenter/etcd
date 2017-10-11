#!/bin/bash

source /etc/etcd/etcd.conf

rm -fr $ETCD_DATA_DIR
mv $ETCD_BACKUP_DIR $ETCD_DATA_DIR
