#!/usr/bin/env bash

set -e

etcdDataDir=$workingDir/default.etcd
etcdEnvFile=/opt/app/conf/etcd.env
etcdName=etcd$MY_SID
etcdClusterToken=etcd-$CLUSTER_ID

buildMemberName() {
  echo etcd${1:-$MY_SID}
}

buildClientUrls() {
  echo http://${1:-$MY_IP}:2379
}

buildMemberUrls() {
  echo http://${1:-$MY_IP}:2380
}

buildMember() {
  echo "$(buildMemberName ${1%=*})=$(buildMemberUrls ${1#*=})"
}

buildEndpoints() {
  for node in $STABLE_NODES; do
    echo "$(buildClientUrls ${node#*=})"
    [ "$1" = "existing" ] && [ "$node" = "$MY_SID=$MY_IP" ] && break
  done
}

buildMembers() {
  local nodes
  nodes="$(echo $STABLE_NODES) $(echo $ADDED_NODES)"
  for node in ${2:-$nodes}; do
    echo "$(buildMember $node)"
    [ "$1" = "existing" ] && [ "$node" = "$MY_SID=$MY_IP" ] && break
  done
}

export ETCDCTL_API=3 
etcdctl() {
  ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd /opt/etcd/current/etcdctl $@
}

takeBackup() {
  ETCDCTL_API=2 runCmd /opt/etcd/v3.3.11/etcdctl backup --data-dir=$etcdDataDir --backup-dir=$1 --with-v3
}

takeSnap() {
  etcdctl snapshot save $1 || return $EC_BACKUP_ERROR
}

restoreSnap() {
  local etcdOpts="
    --skip-hash-check=true
    --name $etcdName
    --data-dir $etcdDataDir
    --initial-cluster $(joinArgs $(buildMembers))
    --initial-cluster-token $etcdClusterToken
    --initial-advertise-peer-urls $(buildMemberUrls)
  "
  etcdctl snapshot restore $@ $etcdOpts || return $EC_RESTORE_ERROR
}

svc() {
  systemctl $@ etcd
}

prepareEtcdConfig() {
  if [ "$MY_ROLE" = "etcd-proxy" ]; then
    cat > $etcdEnvFile << PROXY_ENV_FILE_EOF
etcdOpts="gateway start --listen-addr=$MY_IP:2379 --endpoints=$(joinArgs $(buildEndpoints))"
PROXY_ENV_FILE_EOF
    return 0
  fi

  local state=${1:-new} members
  members="$(joinArgs $(buildMembers $state))"
  members="$(echo $members)"

  cat > $etcdEnvFile << ETCD_ENV_FILE_EOF
ETCD_NAME=$etcdName
ETCD_DATA_DIR=$etcdDataDir
ETCD_LISTEN_PEER_URLS=$(buildMemberUrls)
ETCD_LISTEN_CLIENT_URLS=$(buildClientUrls)
ETCD_INITIAL_ADVERTISE_PEER_URLS=$(buildMemberUrls)
ETCD_ADVERTISE_CLIENT_URLS=$(buildClientUrls)
ETCD_INITIAL_CLUSTER=${members// /,}
ETCD_INITIAL_CLUSTER_TOKEN=$etcdClusterToken
ETCD_AUTO_COMPACTION_RETENTION=$ETCD_COMPACT_INTERVAL
ETCD_INITIAL_CLUSTER_STATE=$state
ETCD_ENV_FILE_EOF
}

hasOnlyV3Data() {
  local v2Keys
  v2Keys=$(ETCDCTL_API=2 etcdctl --endpoints=$(buildClientUrls) ls) || return 1
  [ -z "$v2Keys" ]
}

# $ etctctl member list
# 8c2386146dd0f0ce, unstarted, , http://192.168.2.5:2380,
# b15d3498c7e3a169, started, etcd-1, http://192.168.2.3:2380, http://192.168.2.3:2379

addMember() {
  etcdctl member list | grep -q " ${1#*=}" || etcdctl member add ${1/=/ --peer-urls=}
}

removeMember() {
  local result
  result=$(etcdctl member remove $1)
  [ $? = 0 ] || echo $result | grep -q "etcdserver: member not found"
}

checkMemberStarted() {
  etcdctl member list | grep -q " started, ${1/=/, }"
}

checkMemberRemoved() {
  local members
  members=$(etcdctl member list)
  echo $members | grep -q "${1#*=}" && return $EC_MEMBER_EXISTS || return 0
}

findMemberId() {
  local eps="$(joinArgs $(buildEndpoints))" member
  [ -z "$2" ] || eps=$(buildClientUrls $2)
  member=$(etcdctl --endpoints=$eps member list | grep "http://$1:")
  log "Found member '$member' of '$1' with endpoint $eps ..."
  echo -n ${member%%, *}
}

buildCluster() {
  log "Building cluster with nodes $1 ..."
  for node in $1; do
    local member="$(buildMember $node)"
    if [ "${node%=*}" != "$MY_SID" ]; then
      log "Waiting member $member to fully start ..."
      retry 200 1 checkMemberStarted $member
    else
      log "Adding myself as cluster member ..."
      [ "${STABLE_NODES%%=*}" = "$MY_SID" ] || retry 200 1 addMember $member
      break
    fi
  done
  prepareEtcdConfig existing
  retry 3 1 svc start
}

checkStopped() {
  ! svc is-active -q
}
