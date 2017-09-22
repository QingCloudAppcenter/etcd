#!/bin/bash
ETCDCTL_API=3 etcdctl member add etcd$UNIQUESID --peer-urls=$ETCD_INITIAL_ADVERTISE_PEER_URLS
ETCD_INITIAL_CLUSTER_STATE=existing /usr/local/bin/etcd --name=etcd$UNIQUESID
