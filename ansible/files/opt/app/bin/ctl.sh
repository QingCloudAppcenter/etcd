#!/usr/bin/env bash

set -e

. /opt/app/bin/.env
. /opt/app/bin/changes.env
. /opt/app/bin/common.sh
. /opt/app/bin/etcdutils.sh

command=$1
args="${@:2}"

check() {
  if [ "$MY_ROLE" = "etcd-node" ]; then
    [ "$(curl -s $(buildClientUrls)/health | jq -r '.health')" = "true" ]
  else
    nc -z -w3 $MY_IP 2379
  fi
}

init() {
  [ "$MY_ROLE" = "etcd-proxy" ] || {
    rm -rf $workingDir/lost+found
    mkdir -p $appctlDir
    chown -R etcd.etcd $workingDir
  }
  svc enable
}

metricsKeys="
etcd_network_peer_sent_bytes_total
etcd_server_has_leader
etcd_server_is_leader
etcd_server_leader_changes_seen_total
http_requests_total
process_resident_memory_bytes
process_virtual_memory_bytes
"
metricsFilter="$(echo $metricsKeys | tr " " "|")"
measure() {
  local lines=$(curl -s -m 5 $(buildClientUrls)/metrics | grep -E "^($metricsFilter)" | awk '{gsub(/\{[^}]*\}/,""); a[$1]+=$2}; END{for(c in a) printf "^%s^:%s\n", c, a[c]}')
  cat << METRICS_EOF
{$(echo $lines | tr " " "," | tr "^" '"')}
METRICS_EOF
}

start() {
  if [ "$MY_ROLE" = "etcd-node" ] && [ "$IS_ADDED" = "true" ]; then
    buildCluster "$ADDED_NODES"
  else
    prepareEtcdConfig
    svc start
  fi
}

stop() {
  svc stop
}

destroy() {
  for node in $DELETED_NODES; do
    local member="$(buildMember $node)"
    if [ "${node%=*}" != "$MY_SID" ]; then
      log "Waiting member $member to be removed ..."
      retry 200 1 checkMemberRemoved $member
    else
      local memberId="$(retry 10 1 findMemberId $MY_IP)"
      [ -n "$memberId" ] || return $EC_NO_MEMBER_ID
      log "Removing myself [$member] with ID [$memberId] from cluster ..."
      # This may fail some times until the cluster gets healthy again after removed some other members.
      retry 200 1 removeMember $memberId
      retry 10 1 checkStopped
      stop
      break
    fi
  done
}

v2BackupDir=$workingDir/v2.backup
v3BackupFile=$workingDir/v3.backup
liveDbFile=$etcdDataDir/member/snap/db
backup() {
  rm -rf $v2BackupDir $v3BackupFile*
  local v3Only
  hasOnlyV3Data && v3Only=true || v3Only=false
  if [ "$v3Only" = "true" ]; then
    log "Taking snapshot of v3 data ..."
    check && takeSnap $v3BackupFile || runCmd cp $liveDbFile $v3BackupFile
  else
    svc stop
    log "Taking backup of both v2 and v3 data ..."
    takeBackup $v2BackupDir
    [ "$command" = "repair" ] || svc start
  fi
}

restore() {
  rm -rf $etcdDataDir && sleep 1 && init
  prepareEtcdConfig
  if [ -f "$v3BackupFile" ]; then
    restoreSnap $v3BackupFile
    svc start
  else
    local firstNode=${ALL_NODES%% *}
    local firstNodeIp=${firstNode#*=}
    if [ "$firstNodeIp" = "$MY_IP" ]; then
      [ -d "$v2BackupDir" ] || return $EC_RESTORE_NO_DB
      log "Restoring v2 on first node ..."
      mv $v2BackupDir $etcdDataDir
      log "Starting etcd restore service ..."
      systemctl start etcd-standalone
      log "Updating my peer url ..."
      local myMemberId
      myMemberId=$(findMemberId localhost $MY_IP)
      retry 10 1 etcdctl --endpoints=$(buildClientUrls) member update $myMemberId --peer-urls=$(buildMemberUrls) || {
        systemctl stop etcd-standalone
        return $EC_RESTORE_ERROR
      }
      log "Stopping etcd restore service ..."
      systemctl stop etcd-standalone
    fi
    buildCluster "$ALL_NODES"
  fi
}

restart() {
  stop && start
}

update() {
  svc is-enabled -q || return 0
  [ "$MY_ROLE" = "etcd-proxy" ] || [[ ,${CHANGED_VARS// /,} =~ ,ETCD_COMPACT_INTERVAL= ]] || [[ ,${CHANGED_VARS// /,} =~ ,ETCD_QUOTA_BYTES= ]] || return 0
  restart
}

compact() {
  local latestRev result retCode=0
  latestRev=$(etcdctl get / -w fields | awk -F' : ' '$1=="\"Revision\"" {print $2}')
  result=$(etcdctl compact $latestRev 2>&1) || retCode=$?
  [ $retCode = 0 ] || [[ $result == *"required revision has been compacted" ]] || {
    log "Failed to compact: $result."
    return $retCode
  }
}

checkFileReady() {
  [ -f "$1" ] && [ "$(find $1 -mmin -1)" = "$1" ]
}

ready2Copy=$appctlDir/ready2Copy
ready2Start=$appctlDir/ready2Start
repair() {
  local sourceIp=$(echo "$@" | jq -r '."node.ip"')
  echo "${ALL_NODES// /:}:" | grep -q "=$sourceIp:" || return $EC_REPAIR_ILLEGAL_NODE

  if [ "$sourceIp" = "$MY_IP" ]; then
    backup

    for node in $ALL_NODES; do
      local ip=${node#*=}
      log "Notifying node on $ip ..."
      [ "$ip" = "$MY_IP" ] || ssh $ip "touch $ready2Copy"
    done
    stop

    for node in $ALL_NODES; do
      local ip=${node#*=}
      log "Confirming node on $ip ..."
      [ "$ip" = "$MY_IP" ] || retry 20 1 checkFileReady $ready2Copy-$ip
    done

    if [ -d "$v2BackupDir" ]; then
      local firstNode=${ALL_NODES%% *}
      local firstNodeIp=${firstNode#*=}
      [ "$firstNodeIp" = "$MY_IP" ] || scp -r $v2BackupDir $firstNodeIp:$v2BackupDir
    else
      for node in $ALL_NODES; do
        local ip=${node#*=}
        [ "$ip" = "$MY_IP" ] || scp $v3BackupFile $ip:$v3BackupFile
      done
    fi

    for node in $ALL_NODES; do
      local ip=${node#*=}
      [ "$ip" = "$MY_IP" ] || ssh $ip "touch $ready2Start"
    done
  else
    retry 20 1 checkFileReady $ready2Copy
    stop
    rm -rf $v2BackupDir $v3BackupFile*
    ssh $sourceIp "touch $ready2Copy-$MY_IP"
    retry 200 1 checkFileReady $ready2Start
  fi

  restore
}

$command $args
