#!/bin/bash

source /etc/etcd/etcd.conf

rev=$(ETCDCTL_API=3 /usr/local/bin/etcdctl endpoint status --write-out='json' | egrep -o '\"revision\":[0-9]*' | egrep -o '[0-9]*')
ETCDCTL_API=3 /usr/local/bin/etcdctl compact $rev > compact.log
