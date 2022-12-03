#!/usr/bin/env bash

set -e

. /opt/app/bin/.env
. /opt/app/bin/changes.env
. /opt/app/bin/common.sh
. /opt/app/bin/etcdutils.sh
. /opt/app/bin/nodeexporter.sh
set +e
. /opt/app/bin/tls.sh >/dev/null 2>&1
set -e

command=$1
args="${@:2}"



metricsKeys="
etcd_network_peer_sent_bytes_total
etcd_server_has_leader
etcd_server_is_leader
etcd_server_leader_changes_seen_total
etcd_server_proposals_failed_total
process_resident_memory_bytes
process_virtual_memory_bytes
etcd_debugging_mvcc_range_total
etcd_debugging_mvcc_txn_total
etcd_debugging_mvcc_events_total
process_start_time_seconds
etcd_server_proposals_applied_total
etcd_server_proposals_pending
etcd_network_client_grpc_received_bytes_total
etcd_debugging_mvcc_keys_total
process_cpu_seconds_total
process_open_fds
process_max_fds
etcd_debugging_mvcc_put_total
etcd_debugging_mvcc_db_compaction_keys_total
"
metricsFilter="$(echo $metricsKeys | tr " " "|")"
measure() {
  local lines
  if [ "$ENABLE_TLS" = "true" ]; then
     lines=$(curl -s -m 5 --cacert /var/lib/etcd/ssl/etcd/ca.pem  --cert  /var/lib/etcd/ssl/etcd/client.pem   --key  /var/lib/etcd/ssl/etcd/client-key.pem $(buildClientDomainUrls)/metrics | grep -E "^($metricsFilter)" | awk '{gsub(/\{[^}]*\}/,""); a[$1]+=$2}; END{for(c in a) printf "^%s^:%s\n", c, a[c]}')
  else
     lines=$(curl -s -m 5 $(buildClientUrls)/metrics | grep -E "^($metricsFilter)" | awk '{gsub(/\{[^}]*\}/,""); a[$1]+=$2}; END{for(c in a) printf "^%s^:%s\n", c, a[c]}')
  fi
  echo $lines
}




cluster() {
  etcdctlTemp="/opt/etcd/current/etcdctl"
  set +e
  local nodes=""
  local allNodesNum=0
  local unhealthNodesNum=0
  if [ "$ENABLE_TLS" = "true" ]; then
    nodes="$(echo $STABLE_NODES_DOMAIN_NAME) $(echo $ADDED_NODES_DOMAIN)"
    for node in ${2:-$nodes}; do
      echo "$node" >/dev/null 2>&1
      allNodesNum=`expr ${allNodesNum} + 1`
      `${etcdctlTemp} \
          --cert=/var/lib/etcd/ssl/etcd/client.pem  \
          --key=/var/lib/etcd/ssl/etcd/client-key.pem \
          --cacert=/var/lib/etcd/ssl/etcd/ca.pem  \
          --endpoints=https://etcd${node%=*}${ETCD_CLUSTER_DNS}:2379  endpoint health >/dev/null 2>&1`
      if [ $? -ne 0 ]; then
           unhealthNodesNum=`expr ${unhealthNodesNum} + 1`
      fi
    done
  else
    nodes="$(echo $STABLE_NODES) $(echo $ADDED_NODES)"
    for node in ${2:-$nodes}; do
      echo "$node" >/dev/null 2>&1
      allNodesNum=`expr ${allNodesNum} + 1`
      `${etcdctlTemp} \
          --endpoints=http://${node#*=}:2379  endpoint health >/dev/null 2>&1 `
      if [ $? -ne 0 ]; then
           unhealthNodesNum=`expr ${unhealthNodesNum} + 1`
      fi
    done
  fi
  set -e

  legalMembers=`expr $allNodesNum / 2 + 1`
  echo "legalMembers: $legalMembers" >/dev/null 2>&1

  healthNodesNum=`expr $allNodesNum - $unhealthNodesNum`
  echo "healthNodesNum : $healthNodesNum" >/dev/null 2>&1


  clusterhealth=""
  if [ $allNodesNum -eq $healthNodesNum ]; then
    clusterhealth=0
  elif [ $healthNodesNum -ge $legalMembers ]; then
    clusterhealth=1
  elif [ $healthNodesNum -lt $legalMembers ]; then
    clusterhealth=2
  fi

#  monitorData="$(measure) \"cluster_health\":$clusterhealth"
  monitorData="\"cluster_health\":$clusterhealth"
  cat << METRICS_EOF
{$(echo $monitorData | tr " " "," | tr "^" '"')}
METRICS_EOF
}





node() {
  nodehealth=""
  if [ "$ENABLE_TLS" = "true" ]; then
    if [ "$MY_ROLE" = "etcd-node" ]; then
      [ "$(curl -s  --cacert /var/lib/etcd/ssl/etcd/ca.pem  --cert  /var/lib/etcd/ssl/etcd/client.pem   --key  /var/lib/etcd/ssl/etcd/client-key.pem $(buildClientDomainUrls)/health | jq -r '.health')" = "true" ]
    else
      nc -z -w3 $MY_IP 2379
    fi
  else
    if [ "$MY_ROLE" = "etcd-node" ]; then
      [ "$(curl -s $(buildClientUrls)/health | jq -r '.health')" = "true" ]
    else
      nc -z -w3 $MY_IP 2379
    fi
  fi


  if [ $? -eq 0 ]; then
    nodehealth=0
  else
    nodehealth=1
  fi

  monitorData=""
  if [ "$MY_ROLE" = "etcd-node" ]; then
    monitorData="$(measure) \"node_health\":$nodehealth"
  else
    monitorData="\"node_health\":$nodehealth"
  fi

  cat << METRICS_EOF
{$(echo $monitorData | tr " " "," | tr "^" '"')}
METRICS_EOF

}



$command $args





















