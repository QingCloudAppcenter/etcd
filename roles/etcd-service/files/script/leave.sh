#!/bin/bash
systemctl stop etcd

source /etc/etcd/etcd.conf

ETCDCTL_API=3 etcdctl member remove `source /etc/etcd/etcd.conf; ETCDCTL_API=3 etcdctl member list |grep etcd$UNIQUESID|cut -d ',' -f 1`
