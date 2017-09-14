#!/bin/bash

source /etc/etcd/etcd.conf

ETCDCTL_API=3 etcdctl member remove `etcdctl member list |grep etcd$UNIQUESID|cut -d ',' -f 1`

systemctl stop etcd
