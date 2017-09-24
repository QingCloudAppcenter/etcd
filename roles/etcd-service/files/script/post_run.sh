#!/bin/bash

if [ ! -z $lockid ]
then
  export etcd_endpoint=$( ETCDCTL_API=3 etcdctl endpoint health| grep -v "unhealthy" | head -n 1 | awk '{print $1}' )
  curl $etcd_endpoint/v3alpha/lock/unlock -XPOST -d"{\"key\":\"$lockid\" }"
  rm -rf /etc/etcd/runtime_etcd.conf
fi
