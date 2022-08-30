#!/usr/bin/env bash

set -e

# Error codes
EC_DEFAULT=1               # default
EC_TARGET_ROLE=2           # mis-matched target role
EC_LOGGING=3               # logging: failed to log
EC_RETRY_FAILED=4          # logging: failed to retry
EC_MEMBER_ADD=10           # scale: failed to add node
EC_SCALE_NO_LEAD=11        # scale: failed to find leader
EC_BACKUP_ERROR=12         # restore: failed to backup DB
EC_RESTORE_NO_DB=13        # restore: failed to replica DB file
EC_RESTORE_ERROR=14        # restore: failed to restore DB
EC_MEMBER_EXISTS=15        # scale: member still exists
EC_REPAIR_ILLEGAL_NODE=16  # repair: source node is outside cluster
EC_UNHEALTHY=17            # check: cluster is unhealthy
EC_NO_MEMBER_ID=18         # member: failed to find ID
EC_NO_CA=19                # ca: failed to CA
EC_REPAIR_FAILED=20        # repair: failed to repair
EC_REPAIR_IP_FAILED=21        # repair: Normal node input error or Abnormal node input error

workingDir=/var/lib/etcd
appctlDir=$workingDir/appctl  # Log Dir

log() {
  logger -t $MY_ROLE.appctl --id=$$ [cmd=$command role=$MY_ROLE] "$@" || return $EC_LOGGING
}

runCmd() {
  sudo -E -u etcd $@
}

retry() {
  local tried=0 maxAttempts=$1 interval=$2 cmd="${@:3}" retCode=$EC_RETRY_FAILED
  while [ $tried -lt $maxAttempts ]; do
    sleep $interval
    tried=$((tried+1))
    $cmd && return 0 || {
      retCode=$?
      log "'$cmd' ($tried/$maxAttempts) returned an error."
    }
  done

  log "'$cmd' still returned errors after $tried attempts. Stopping ..." && return $retCode
}

joinArgs() {
  local args="$(echo "$@")"
  echo ${args// /,}
}
