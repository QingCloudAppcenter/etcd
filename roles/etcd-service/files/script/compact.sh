#!/bin/bash

source /etc/etcd/etcd.conf

ETCDCTL_API=3

etcdctl compaction
