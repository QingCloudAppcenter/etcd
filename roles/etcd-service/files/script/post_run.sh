#!/bin/bash

if [ ! -z $lockid ]
then
  curl $etcd_endpoint/v3alpha/lock/unlock -XPOST -d"{\"key\":\"$lockid\" }"
fi
