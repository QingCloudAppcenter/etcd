#!/bin/bash

if [ ! -z $lockid ]
then
  curl $etcd_endpoint:2379/v3alpha/lock/unlock -XPOST -d"{\"key\":\"$lockid\" }"
  pkill etcdctl
  rm -rf /etc/etcd/runtime_etcd.conf
fi
