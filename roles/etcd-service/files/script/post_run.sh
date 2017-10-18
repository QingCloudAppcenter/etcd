#!/bin/bash

if [ ! -z $lockid ]
then
  sleep 10
  curl $etcd_endpoint:2379/v3alpha/lock/unlock -XPOST -d"{\"key\":\"$lockid\" }"
  pkill etcdctl
fi
