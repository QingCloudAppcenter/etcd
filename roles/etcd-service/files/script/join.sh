#!/bin/bash
if [ -f $ETCD_DATA_DIR ]
then
  echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/runtime_etcd.conf
elif [[ $ADDING_HOST_NUM -ne 0 ]]
then
  index=0
  unset ETCDCTL_ENDPOINTS
  while [ "$index" -lt $HOST_NUM ]
  do
    hostIpname=HOST_$index
    echo >/dev/tcp/${!hostIpname}/2379 && \
    if [[ -z $ETCDCTL_ENDPOINTS ]];
    then
      ETCDCTL_ENDPOINTS=http://${!hostIpname}:2379
    else
      ETCDCTL_ENDPOINTS=$ETCDCTL_ENDPOINTS,http://${!hostIpname}:2379
    fi && etcd_endpoint=${!hostIpname}
    index=$(($index + 1 ))
  done
  echo ETCDCTL_ENDPOINTS=$ETCDCTL_ENDPOINTS >>  /etc/etcd/runtime_etcd.conf
  echo etcd_endpoint=$etcd_endpoint >> /etc/etcd/runtime_etcd.conf
  lid=$(ETCDCTL_API=3 etcdctl --endpoints=$ETCDCTL_ENDPOINTS -w fields lease grant 60 | grep '"ID"' | awk ' { print $3 } ')
  echo lockid=$(curl $etcd_endpoint:2379/v3alpha/lock/lock -XPOST -d"{\"name\":\"ZXRjZGNsdXN0ZXJsb2Nr\", \"lease\" : $lid }"|jq '.key' ) >>  /etc/etcd/runtime_etcd.conf

  unset ETCD_INITIAL_CLUSTER
  ETCDCTL_API=3 etcdctl member list --endpoints=$ETCDCTL_ENDPOINTS |grep ' started' | awk -F \,  '{ gsub(/ /, "", $0);print $3"="$4 }'|{  while read node; do  if [[ -z $ETCD_INITIAL_CLUSTER ]]; then export ETCD_INITIAL_CLUSTER=$node; else export ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER,$node; fi; done; echo ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER,etcd$UNIQUESID=$ETCD_INITIAL_ADVERTISE_PEER_URLS >>  /etc/etcd/runtime_etcd.conf ; }

  ETCDCTL_API=3 etcdctl member add etcd$UNIQUESID --peer-urls=$ETCD_INITIAL_ADVERTISE_PEER_URLS --endpoints=$ETCDCTL_ENDPOINTS

  echo ETCD_INITIAL_CLUSTER_STATE=existing >> /etc/etcd/runtime_etcd.conf
  cat /etc/etcd/runtime_etcd.conf
fi
