#!/bin/bash
if [ -f $ETCD_DATA_DIR ]
then
echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/runtime_etcd.conf
elif [[ $( ETCDCTL_API=3 etcdctl endpoint health ) ]]
then
export etcd_endpoint=$( ETCDCTL_API=3 etcdctl endpoint health | grep -v "unhealthy" | head -n 1 | awk '{print $1}' )
lid=$(ETCDCTL_API=3 etcdctl -w fields lease grant 60 | grep '"ID"' | awk ' { print $3 } ')
echo lockid=$(curl $etcd_endpoint/v3alpha/lock/lock -XPOST -d"{\"name\":\"ZXRjZGNsdXN0ZXJsb2Nr\", \"lease\" : $lid }"|jq '.key' ) >>  /etc/etcd/runtime_etcd.conf

ETCDCTL_API=3 etcdctl member list --endpoints=$ETCDCTL_ENDPOINTS |grep started | awk -F \,  '{ gsub(/ /, "", $0);print $3"="$4 }'| while read node; do  if [[ -z ETCD_INITIAL_CLUSTER ]]; then export ETCD_INITIAL_CLUSTER=$node; else export ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER,$node; fi; done

echo ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER,etcd$UNIQUESID=$ETCD_INITIAL_ADVERTISE_PEER_URLS >>  /etc/etcd/runtime_etcd.conf

ETCDCTL_API=3 etcdctl member add etcd$UNIQUESID --peer-urls=$ETCD_INITIAL_ADVERTISE_PEER_URLS
echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/runtime_etcd.conf
fi
