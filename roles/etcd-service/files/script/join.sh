#!/bin/bash
if [ -f $ETCD_DATA_DIR ]
then
echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/etcd.conf
elif [[ $( ETCDCTL_API=3 etcdctl endpoint health --endpoints=$ETCDCTL_ENDPOINTS) ]]
then
echo etcd_endpoint=$( ETCDCTL_API=3 etcdctl endpoint health --endpoints=$ETCDCTL_ENDPOINTS | grep -v "unhealthy" | head -n 1 | awk '{print $1}' ) >>  /etc/etcd/etcd.conf
lid=$(ETCDCTL_API=3 etcdctl -w fields lease grant 60 --endpoints=$ETCDCTL_ENDPOINTS| grep '"ID"' | awk ' { print $3 } ')
echo lockid=$(curl $etcd_endpoint/v3alpha/lock/lock -XPOST -d"{\\\"name\\\":\\\"ZXRjZGNsdXN0ZXJsb2Nr\\\", \\\"lease\\\" : $lid }"|jq '.key' ) >>  /etc/etcd/etcd.conf

ETCDCTL_API=3 etcdctl member add etcd$UNIQUESID --peer-urls=$ETCD_INITIAL_ADVERTISE_PEER_URLS
echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/etcd.conf
fi
