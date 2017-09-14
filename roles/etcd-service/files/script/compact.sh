#!/bin/bash

source /etc/etcd/etcd.conf

rev=$(ETCDCTL_API=3 etcdctl --endpoints=:2379 endpoint status --write-out='json' | egrep -o '\"revision\":[0-9]*' | egrep -o '[0-9]*')
ETCDCTL_API=3 etcdctl compact $rev > compact.log
