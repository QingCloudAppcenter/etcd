#!/usr/bin/env bash

set -e

#. /opt/app/bin/etcdauth.sh

etcdDataDir=$workingDir/default.etcd
etcdEnvFile=/opt/app/conf/etcd.env
etcdName=etcd$MY_SID
etcdClusterToken=etcd-$CLUSTER_ID
#etcdAuthPasswdFile=$workingDir/etcdAuthPasswd.txt


buildMemberName() {
  echo etcd${1:-$MY_SID}
}

buildClientUrls() {
  if [ $ENABLE_TLS = "true" ]; then
     echo https://${1:-$MY_IP}:2379
  else
     echo http://${1:-$MY_IP}:2379
  fi
}

buildClientDomainUrls() {
  if [ $ENABLE_TLS = "true" ]; then
     echo https://${1:-etcd${MY_SID}${ETCD_CLUSTER_DNS}}:2379
  else
     echo http://${1:-$MY_IP}:2379
  fi
}

buildMemberUrls() {
  if [ $ENABLE_TLS = "true" ]; then
     echo https://${1:-$MY_IP}:2380
  else
     echo http://${1:-$MY_IP}:2380
  fi
}

buildMemberDomainUrls() {
  if [ $ENABLE_TLS = "true" ]; then
     echo https://${1:-etcd${MY_SID}${ETCD_CLUSTER_DNS}}:2380
  else
     echo http://${1:-$MY_IP}:2380
  fi
}

buildMember() {
  if [ $ENABLE_TLS = "true" ]; then
     echo "$(buildMemberName ${1%=*})=$(buildMemberDomainUrls ${1#*=})"
  else
     echo "$(buildMemberName ${1%=*})=$(buildMemberUrls ${1#*=})"
  fi

}

buildEndpoints() {
  if [ $ENABLE_TLS = "true" ]; then
    for node in $STABLE_NODES_DOMAIN_NAME; do
      echo "$(buildClientUrls ${node#*=})"
      [ "$1" = "existing" ] && [ "$node" = "$MY_SID=etcd${MY_SID}${ETCD_CLUSTER_DNS}" ] && break
    done
  else
    for node in $STABLE_NODES; do
      echo "$(buildClientUrls ${node#*=})"
      [ "$1" = "existing" ] && [ "$node" = "$MY_SID=$MY_IP" ] && break
    done
  fi
}

buildMembers() {
  local nodes
  if [ $ENABLE_TLS = "true" ]; then
    nodes="$(echo $STABLE_NODES_DOMAIN_NAME) $(echo $ADDED_NODES_DOMAIN)"
    for node in ${2:-$nodes}; do
      echo "$(buildMember $node)"
      [ "$1" = "existing" ] && [ "$node" = "$MY_SID=etcd${MY_SID}${ETCD_CLUSTER_DNS}" ] && break
    done
  else
    nodes="$(echo $STABLE_NODES) $(echo $ADDED_NODES)"
    for node in ${2:-$nodes}; do
      echo "$(buildMember $node)"
      [ "$1" = "existing" ] && [ "$node" = "$MY_SID=$MY_IP" ] && break
    done
  fi
}

buildMembersDomain() {
  local nodes
  nodes="$(echo $STABLE_NODES_DOMAIN_NAME) $(echo $ADDED_NODES_DOMAIN)"
  for node in ${2:-$nodes}; do
    echo "$(buildMember $node)"
    [ "$1" = "existing" ] && [ "$node" = "$MY_SID=etcd${MY_SID}${ETCD_CLUSTER_DNS}" ] && break
  done
}

etcdctlInitFun() {
  if [ $ENABLE_TLS = "true" ]; then
     echo "/opt/etcd/current/etcdctl  --cert=/var/lib/etcd/ssl/etcd/client.pem  --key=/var/lib/etcd/ssl/etcd/client-key.pem  --cacert=/var/lib/etcd/ssl/etcd/ca.pem"
  else
     echo "/opt/etcd/current/etcdctl"
  fi
}

export ETCDCTL_API=3
etcdctl() {
   etcdctlInit=$(etcdctlInitFun)
#   if [ $ETCDAUTH = "false" ] ;then
   ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd  $etcdctlInit $@
#   else
#    ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd $etcdctlInit  --user="${ETCDDEFAULTUSER}:${ETCDDEFAULTPASSWD}" $@
#   fi
}

takeBackup() {
  local etcdctlInit=$(etcdctlInitFun)
  if [ $ENABLE_TLS = "true" ]; then
     etcdctlInit=`echo ${etcdctlInit}|sed "s/--cert/--cert-file/g"|sed "s/--key/--key-file/g"|sed "s/--cacert/--ca-file/g"`
  fi
  ETCDCTL_API=2 runCmd $etcdctlInit backup --data-dir=$etcdDataDir --backup-dir=$1 --with-v3
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
    if [ $ENABLE_TLS = "true" ]; then
      cat > $etcdEnvFile << PROXY_ENV_FILE_EOF
etcdOpts="gateway start --listen-addr=proxy${MY_SID}${ETCD_CLUSTER_DNS}:2379 --endpoints=$(joinArgs $(buildEndpoints))"
PROXY_ENV_FILE_EOF
      return 0
    else
      cat > $etcdEnvFile << PROXY_ENV_FILE_EOF
etcdOpts="gateway start --listen-addr=$MY_IP:2379 --endpoints=$(joinArgs $(buildEndpoints))"
PROXY_ENV_FILE_EOF
      return 0
    fi
  fi

  local state=${1:-new} members
  if [ $ENABLE_TLS = "true" ]; then
    members="$(joinArgs $(buildMembersDomain $state))"
  else
    members="$(joinArgs $(buildMembers $state))"
  fi
  members="$(echo $members)"

  if [ $ENABLE_TLS = "true" ]; then
    cat > $etcdEnvFile << ETCD_ENV_FILE_EOF
ETCD_NAME=$etcdName
ETCD_DATA_DIR=$etcdDataDir
ETCD_LISTEN_PEER_URLS=$(buildMemberUrls)
ETCD_LISTEN_CLIENT_URLS=$(buildClientUrls)
ETCD_INITIAL_ADVERTISE_PEER_URLS=$(buildMemberDomainUrls)
ETCD_ADVERTISE_CLIENT_URLS=$(buildClientDomainUrls)
ETCD_INITIAL_CLUSTER=${members// /,}
ETCD_INITIAL_CLUSTER_TOKEN=$etcdClusterToken
ETCD_AUTO_COMPACTION_RETENTION=$ETCD_COMPACT_INTERVAL
ETCD_AUTO_COMPACTION_MODE=$ETCD_AUTO_COMPACTION_MODE
ETCD_QUOTA_BACKEND_BYTES=$ETCD_QUOTA_BYTES
ETCD_HEARTBEAT_INTERVAL=$ETCD_HEARTBEAT_INTERVAL
ETCD_ELECTION_TIMEOUT=$ETCD_ELECTION_TIMEOUT
ETCD_INITIAL_CLUSTER_STATE=$state
ETCD_ENABLE_V2=$ETCD_ENABLE_V2
ETCD_CERT_FILE=/var/lib/etcd/ssl/etcd/server.pem
ETCD_KEY_FILE=/var/lib/etcd/ssl/etcd/server-key.pem
ETCD_PEER_CERT_FILE=/var/lib/etcd/ssl/etcd/peer.pem
ETCD_PEER_KEY_FILE=/var/lib/etcd/ssl/etcd/peer-key.pem
ETCD_TRUSTED_CA_FILE=/var/lib/etcd/ssl/etcd/ca.pem
ETCD_PEER_TRUSTED_CA_FILE=/var/lib/etcd/ssl/etcd/ca.pem
ETCD_PEER_CLIENT_CERT_AUTH=true
ETCD_CLIENT_CERT_AUTH=true
ETCD_ENV_FILE_EOF
  else
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
ETCD_AUTO_COMPACTION_MODE=$ETCD_AUTO_COMPACTION_MODE
ETCD_QUOTA_BACKEND_BYTES=$ETCD_QUOTA_BYTES
ETCD_HEARTBEAT_INTERVAL=$ETCD_HEARTBEAT_INTERVAL
ETCD_ELECTION_TIMEOUT=$ETCD_ELECTION_TIMEOUT
ETCD_INITIAL_CLUSTER_STATE=$state
ETCD_ENABLE_V2=$ETCD_ENABLE_V2
ETCD_ENV_FILE_EOF
  fi
}

hasOnlyV3Data() {
  local v2Keys
  if [ $ENABLE_TLS = "true" ]; then
    local etcdctlInit=$(etcdctlInitFun)
    etcdctlInit=`echo ${etcdctlInit}|sed "s/--cert/--cert-file/g"|sed "s/--key/--key-file/g"|sed "s/--cacert/--ca-file/g"`
    v2Keys=`$(ETCDCTL_API=2 $etcdctlInit --endpoints=$(buildClientDomainUrls) ls)` || return 1
  else
    v2Keys=`$(ETCDCTL_API=2 etcdctl --endpoints=$(buildClientUrls) ls)` || return 1
  fi
  [ -z "$v2Keys" ]
}

# $ etctctl member list
# 8c2386146dd0f0ce, unstarted, , https://192.168.2.5:2380,
# b15d3498c7e3a169, started, etcd-1, https://192.168.2.3:2380, https://192.168.2.3:2379

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
  member=""
  result=`echo "$1"|grep ${ETCD_CLUSTER_DNS}`
  if [ "$result" != "" ];then
     member=$(etcdctl   member list | grep "https://$1:")
  else
     member=$(etcdctl   member list | grep "http://$1:")
  fi
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

#-----用户认证功能开始-------
updateEtcdPasswdFile(){
  echo "EtcdRootOriginalPasswd=${ETCDDEFAULTPASSWD}">$etcdAuthPasswdFile
}

updateEtcdPasswd(){
  EtcdRootOriginalPasswd=`cat $etcdAuthPasswdFile |tr '=' ' '|awk '{print $2}'`
  etcdctlInit=$(etcdctlInitFun)
  ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd $etcdctlInit  --user="${ETCDDEFAULTUSER}:${EtcdRootOriginalPasswd}" user passwd root <<END
${ETCDDEFAULTPASSWD}
${ETCDDEFAULTPASSWD}
END
  updateEtcdPasswdFile
}

etcdctlReverse() {
   etcdctlInit=$(etcdctlInitFun)
   if [ $ETCDAUTH = "true" ] ;then
    ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd $etcdctlInit $@
   else
    ETCDCTL_ENDPOINTS=$(joinArgs $(buildEndpoints)) runCmd $etcdctlInit  --user="${ETCDDEFAULTUSER}:${ETCDDEFAULTPASSWD}" $@
   fi
}

isExistEtcdDefaultUser(){
   etcdctlReverse user get ${ETCDDEFAULTUSER}
}

addEtcdDefaultUser(){
     etcdctlReverse user add ${ETCDDEFAULTUSER} <<END
${ETCDDEFAULTPASSWD}
${ETCDDEFAULTPASSWD}
END
}


updateEtcdAuth(){
   #查询是否有root用户，没有就创建
  isExistEtcdDefaultUser || addEtcdDefaultUser
  updateEtcdPasswdFile
  if [ $ETCDAUTH = "true" ] ;then
    etcdctlReverse auth enable
  else
    etcdctlReverse auth disable
  fi
}
#-----用户认证功能结束-------

#----单节点恢复功能开始-------
stopNodeEtcdService(){
  if [ -f "/etc/systemd/system/etcd.service" ];then
    systemctl stop etcd
    mv /etc/systemd/system/etcd.service  /etc/systemd/system/etcd1.service
    systemctl daemon-reload
  fi
}


removeNodeAndaddNodeAgain(){
  healthNode=$1
  etcdctlInit=$(etcdctlInitFun)

  #1.先从member list中通过endpoint health找到不健康的节点，并移除
  allNodeClientURL=`$etcdctlInit member list --endpoints=${healthNode} |awk '{print $5}'|sed s/,/""/g|grep -v '^$'`
  set +e
  for nodeClientURL in $allNodeClientURL;do
      echo "check nodeClientURL:$nodeClientURL health"
      $etcdctlInit endpoint health  --endpoints=${nodeClientURL}
      if [ $? -ne 0 ]; then
         # 查看集群节点列表
         unHealthNodeSerialNum=`$etcdctlInit member list --endpoints=${healthNode} |grep ${nodeClientURL%:*}|awk -F ',' '{print $1}'`
         # 1ce6d6d01109192, started, etcd03, http://192.168.0.102:2380, http://192.168.0.102:2379
         # 9b534175b46ea789, started, etcd01, http://192.168.0.100:2380, http://192.168.0.100:2379
         # ac2f188e97f50eb7, started, etcd02, http://192.168.0.101:2380, http://192.168.0.101:2379
         # 移除问题节点
         $etcdctlInit member remove ${unHealthNodeSerialNum} --endpoints=${healthNode}
      fi
  done
  #2.先从member list中状态不是started，并移除
  unstartedMemIDs=`$etcdctlInit member list --endpoints=${healthNode}  |grep  "unstarted"|awk -F ',' '{print $1}'`
  for unstartedMemID in $unstartedMemIDs;do
       echo "remove unhealth node,NodeSerialNum: $unstartedMemID"
      if [ $unstartedMemID != "" ];then
        # 移除问题节点
         $etcdctlInit member remove ${unstartedMemID} --endpoints=${healthNode}
      fi
  done

   #每个节点只添加自己
  unHealthNodeName=$(buildMemberName)
  $etcdctlInit member add ${unHealthNodeName} --peer-urls="$(buildMemberDomainUrls)" --endpoints=${healthNode}
  set -e
}


modifyCfgAndRestart(){
   healthNode=$1
   etcdctlInit=$(etcdctlInitFun)
   rm -rf  /var/lib/etcd/default.etcd
   cp /opt/app/conf/etcd.env  /opt/app/conf/etcd1.env
   sed -i 's/ETCD_INITIAL_CLUSTER_STATE=new/ETCD_INITIAL_CLUSTER_STATE=existing/g' /opt/app/conf/etcd1.env
   sed -i 's/etcd.env/etcd1.env/g'  /etc/systemd/system/etcd1.service
   # 留下自己的 和 memberl list
   allHealthnodelist=`$etcdctlInit   --endpoints=${healthNode} member list|grep -v unstarted|grep started |awk '{print $3"="$4}'|sed s/,/""/g`
   echo "allHealthnodelist:$allHealthnodelist"
   local ETCD_INITIAL_CLUSTER_values=""
   for var in $allHealthnodelist;do
      ETCD_INITIAL_CLUSTER_values=${ETCD_INITIAL_CLUSTER_values}${var}","
   done
   unHealthNode=$(buildMemberDomainUrls)
   unHealthNodeName=$(buildMemberName)
   ETCD_INITIAL_CLUSTER_values=${ETCD_INITIAL_CLUSTER_values}${unHealthNodeName}"="${unHealthNode}
   echo "ETCD_INITIAL_CLUSTER_values:$ETCD_INITIAL_CLUSTER_values"

   sed -i "/^ETCD_INITIAL_CLUSTER=/d" /opt/app/conf/etcd1.env
   echo "ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER_values" >> /opt/app/conf/etcd1.env
   systemctl daemon-reload
   systemctl start etcd1.service
}


verifyClusterHealth(){
    etcdctlInit=$(etcdctlInitFun)
    sleepMaxTime=0
    eixtFlag=0
    num=0
    sleepTime=2
    while :
      do
      num=`expr ${num} + 1`
      echo " loop check cluster ,Check every ${sleepTime} seconds!"
      $etcdctlInit endpoint health  --endpoints=$(buildClientDomainUrls)
      if [ $? -eq 0 ]; then
          break
      fi
      #循环验证多少秒,健康就返回正常,不健康就返回异常
	    if [ ${sleepMaxTime} -ge 600 ];then
	        echo "sleepMaxTime>=600,exit  check  ${ip} ${checkPort} loop "
	        eixtFlag=20
	        break
	    fi

	    sleepMaxTime=`expr ${sleepMaxTime} + ${sleepTime}`
      sleep ${sleepTime}s
      done

    if [ ${eixtFlag} -ne 0 ];then
        echo " ${ip} node repair fail！"
        log  " ${ip} node repair fail！"; return $EC_REPAIR_FAILED
    fi
}

machineEnvRecovery(){
   mv /etc/systemd/system/etcd1.service  /etc/systemd/system/etcd.service
   rm -rf /opt/app/conf/etcd1.env
   sed -i 's/etcd1.env/etcd.env/g'  /etc/systemd/system/etcd.service
   systemctl daemon-reload
   systemctl stop  etcd1
   systemctl start etcd
}
#----单节点恢复功能结束-------