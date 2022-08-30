#!/usr/bin/env bash

set -e

. /opt/app/bin/.env
. /opt/app/bin/changes.env
. /opt/app/bin/common.sh
. /opt/app/bin/etcdutils.sh
. /opt/app/bin/nodeexporter.sh
. /opt/app/bin/tls.sh

command=$1
args="${@:2}"
etcdVersion=v3.4.16
check() {
  if [ $ENABLE_TLS = "true" ]; then
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
}


updateNodeexporterServer(){

  if [ $NODE_EXPORTER = "true" ] ;then
    log "NODE_EXPORTER service is preparing to start"
    systemctl start node_exporter
    if [ $? -eq 0 ] ;then
        log "NODE_EXPORTER service  start success"
    fi
  else
    log "NODE_EXPORTER service is preparing to stop"
    systemctl stop node_exporter
    if [ $? -eq 0 ] ;then
        log "NODE_EXPORTER service  stop success"
    fi
  fi
}

generateCertificate(){
  openTLSAndChangeDomain=$1
  if [ "$openTLSAndChangeDomain" = "true" ] || [ ! -f "/var/lib/etcd/ssl/etcd/ca.pem" ] ;then
  local etcd_nodeAllIp='"'`curl -s -m 15   metadata/self/hosts/etcd_node/|grep /ip|grep -v eip|awk '{print $2}'|egrep '([0-9]{1,3}\.){3}[0-9]{1,3}'|sed ':label;N;s/\n/","/;b label'`'"'
  echo '{"CN":"CA","key":{"algo":"rsa","size":2048},"ca":{"expiry": "876000h"}}' | /usr/local/bin/cfssl gencert -initca - | /usr/local/bin/cfssljson -bare ca -
  echo '{"signing":{"default":{"expiry":"876000h"},"profiles":{"server":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]},"client":{"expiry":"876000h","usages":["signing","key encipherment","client auth"]},"peer":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]}}}}' > ca-config.json
  export NAME=server
  echo '{"CN":"'$NAME'","hosts":["*'${ETCD_CLUSTER_DNS}'"],"key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -ca=ca.pem -ca-key=ca-key.pem -profile=server - | /usr/local/bin/cfssljson -bare $NAME
  export NAME=client
  echo '{"CN":"'$NAME'","key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -profile=client -ca=ca.pem -ca-key=ca-key.pem  - | /usr/local/bin/cfssljson -bare $NAME -
  export NAME=peer
  echo '{"CN":"'$NAME'","hosts":["*'${ETCD_CLUSTER_DNS}'"],"key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -ca=ca.pem -ca-key=ca-key.pem -profile=peer - | /usr/local/bin/cfssljson -bare $NAME


  mkdir -p  /var/lib/etcd/ssl/etcd/
  cp ./*.pem  /var/lib/etcd/ssl/etcd/
  chown -R etcd:etcd  /var/lib/etcd/ssl/etcd/

  allIps=`curl -s  -m 15 metadata/self|grep '/ip'|awk '{print  $2}'|sort|uniq|egrep '([0-9]{1,3}\.){3}[0-9]{1,3}'`
  ipArr=(${allIps// / })
  for  ip  in ${ipArr[@]}
  do
     echo "scp cert to ${ip}"
     if [ ${ip} != ${MY_IP} ];then
       scp -P 16022 -rp /var/lib/etcd/ssl  ${ip}:/var/lib/etcd
       ssh -p 16022 ${ip} "chown -R etcd:etcd  /var/lib/etcd/ssl"
     fi
  done

  /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/caPem  "$(base64  <<< cat /var/lib/etcd/ssl/etcd/ca.pem)"
  /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/clientPem   "$(base64  <<< cat /var/lib/etcd/ssl/etcd/client.pem)"
  /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/clientKeyPem "$(base64  <<< cat /var/lib/etcd/ssl/etcd/client-key.pem)"


  fi
}


configureDomainName(){
#   local isDomain=`cat /etc/hosts|grep "${MY_IP}"`
#   if [  "${isDomain}" = "" ]; then
#      echo "$HOSTS_DOMAIN_NAME"  |awk '{len=split($0,a," ");for(i=1;i<=len;i=i+2) print a[i]"\t"a[i+1] }'  >> /etc/hosts
#   fi
   NODES_HOSTS="$HOSTS_DOMAIN_NAME $PROXY_HOSTS_DOMAIN_NAME"
   echo $NODES_HOSTS
   if [  "${NODES_HOSTS}" != "" ]; then
      count=0
      memberIP=""
      for var in $NODES_HOSTS;do
           if [ "$count" -eq "0" ] ;then
              memberIP=$var
           else
             sed -i "/${var}$/d" /etc/hosts
             echo "$memberIP" "$var"  >> /etc/hosts
           fi
           count=`expr $count + 1`
           if [ "$count" -eq "2" ]; then
             count=0
           fi

      done
   fi
   ADDED_NODES_HOSTS="$ADDED_NODES_HOSTS_DOMAIN"
   if [  "${ADDED_NODES_HOSTS}" != "" ]; then
      count=0
      memberIP=""
      for var in $ADDED_NODES_HOSTS;do
           if [ "$count" -eq "0" ] ;then
              memberIP=$var
           else
             sed -i "/${var}$/d" /etc/hosts
             echo "$memberIP" "$var"  >> /etc/hosts
           fi
           count=`expr $count + 1`
           if [ "$count" -eq "2" ]; then
             count=0
           fi
      done
   fi
   echo "IS_DELETED value:$IS_DELETED "
   if [ "$IS_DELETED" != "true" ];then
      #未删除的节点,删除hosts文件中多余的域名与ip的对应关系
      hostsAllDomain=`cat /etc/hosts|grep -e ${ETCD_CLUSTER_DNS}|awk '{print $1 "  " $2}'`
      DELETED_NODES_HOSTS="$DELETED_NODES_HOSTS_DOMAIN"
      if [ "${hostsAllDomain}" != "" ] && [ "${DELETED_NODES_HOSTS}" != "" ]; then
         local count=0
         for var in $hostsAllDomain;do
             count=`expr $count + 1`
             if [ "$count" -eq "2" ]; then
               local delNode=`echo ${DELETED_NODES_HOSTS} |grep ${var}`
               if [  "${delNode}" != "" ]; then
                sed -i "/${var}$/d" /etc/hosts
               fi
               count=0
             fi
         done
      fi
   fi

   /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/hostsDomain "$HOSTS_DOMAIN_NAME $ADDED_NODES_HOSTS_DOMAIN $PROXY_HOSTS_DOMAIN_NAME "
}




init() {
  if [ "$MY_ROLE" = "etcd-proxy" ]; then
    rm -rf $workingDir/lost+found
    mkdir -p $appctlDir
    chown -R etcd.etcd $workingDir
  fi

#  if [ "$MY_ROLE" = "etcd-node" ] && [ "$IS_ADDED" != "true" ]; then
#   updateEtcdAuth
#  fi
}

initCustom(){
  #第一ip执行其他的都不执行，其它等待这个执行完了，再执行start
  firstNode=`echo $STABLE_NODES|awk '{print $1}'`
  firstNodeSID=`echo ${firstNode%=*}`
  firstNodeIP=`echo ${firstNode#*=}`
  if [ "$MY_ROLE" = "etcd-node" ] && [ $ENABLE_TLS = "true" ] && [ "$IS_ADDED" != "true" ] && [ $MY_SID =  $firstNodeSID ]; then
      generateCertificate
  fi


  sleepMaxTime=0
  eixtFlag=0
  num=0
  sleepTime=2
  while :
    do
    num=`expr ${num} + 1`
    echo "This is the ${num} time to check whether there is a certificate"
#    caPem=`curl -s metadata/self/env/caPem`
#    clientPem=`curl -s metadata/self/env/clientPem`
#    clientKeyPem=`curl -s metadata/self/env/clientKeyPem`
    caKeyPem="/var/lib/etcd/ssl/etcd/ca-key.pem"
    caPem="/var/lib/etcd/ssl/etcd/ca.pem"
    clientKeyPem="/var/lib/etcd/ssl/etcd/client-key.pem"
    clientPem="/var/lib/etcd/ssl/etcd/client.pem"
    peerKeyPem="/var/lib/etcd/ssl/etcd/peer-key.pem"
    peerPem="/var/lib/etcd/ssl/etcd/peer.pem"
    serverKeyPem="/var/lib/etcd/ssl/etcd/server-key.pem"
    serverPem="/var/lib/etcd/ssl/etcd/server.pem"
    if [  -f $caKeyPem ] && [  -f $caPem ] && [  -f $clientKeyPem ] && [  -f $clientPem ] && [  -f $peerKeyPem ] && [  -f $peerPem ] && [  -f $serverKeyPem ] && [  -f $serverPem ]; then
        echo "ca-key.pem  ca.pem  client-key.pem  client.pem  peer-key.pem  peer.pem  server-key.pem  server.pem,their certificates exist"
        break
    fi

	  if [ ${sleepMaxTime} -ge 120 ];then
	      echo "sleepMaxTime>=120s,exit  check  Certificate loop "
	      eixtFlag=19
	      break
	  fi

	  sleepMaxTime=`expr ${sleepMaxTime} + ${sleepTime}`
    sleep ${sleepTime}s
    done

  if [ ${eixtFlag} -ne 0 ];then
      echo "Certificate check failed！"
      log  "Certificate check failed"; return $EC_NO_CA
  fi

}


initETCDenv() {

  [ "$MY_ROLE" = "etcd-proxy" ] || {
    rm -rf $workingDir/lost+found
    mkdir -p $appctlDir
    chown -R etcd.etcd $workingDir
  }
  svc enable
  updateNodeexporterServer

  if [ $ENABLE_TLS = "true" ]; then
    configureDomainName
  fi

  if [ "$MY_ROLE" = "etcd-node" ] && [ $ENABLE_TLS = "true" ] && [ "$IS_ADDED" != "true" ]; then
      initCustom
  fi
}

metricsKeys="
etcd_network_peer_sent_bytes_total
etcd_server_has_leader
etcd_server_is_leader
etcd_server_leader_changes_seen_total
etcd_server_proposals_failed_total
process_resident_memory_bytes
process_virtual_memory_bytes
"
metricsFilter="$(echo $metricsKeys | tr " " "|")"
measure() {
  local lines
  if [ $ENABLE_TLS = "true" ]; then
     lines=$(curl -s -m 5 --cacert /var/lib/etcd/ssl/etcd/ca.pem  --cert  /var/lib/etcd/ssl/etcd/client.pem   --key  /var/lib/etcd/ssl/etcd/client-key.pem $(buildClientDomainUrls)/metrics | grep -E "^($metricsFilter)" | awk '{gsub(/\{[^}]*\}/,""); a[$1]+=$2}; END{for(c in a) printf "^%s^:%s\n", c, a[c]}')
  else
     lines=$(curl -s -m 5 $(buildClientUrls)/metrics | grep -E "^($metricsFilter)" | awk '{gsub(/\{[^}]*\}/,""); a[$1]+=$2}; END{for(c in a) printf "^%s^:%s\n", c, a[c]}')
  fi
  cat << METRICS_EOF
{$(echo $lines | tr " " "," | tr "^" '"')}
METRICS_EOF
}

start() {
  initETCDenv
  log "Etcd service is preparing to start"
  if [ "$MY_ROLE" = "etcd-node" ] && [ "$IS_ADDED" = "true" ]; then
    if [ $ENABLE_TLS = "true" ]; then
       echo "View current changes.env document content:" `cat /opt/app/bin/changes.env`
       echo "View current hosts document content:" `cat /etc/hosts`
       echo "View current MY_ROLE vlaue:" $MY_ROLE ",IS_ADDED  vlaue:" $IS_ADDED ",ENABLE_TLS vlaue:"$ENABLE_TLS
       local isDomain=`cat /etc/hosts|grep "${MY_IP}"`
       echo "View current isDomain vlaue:" $isDomain
       if [  "${isDomain}" = "" ]; then
         allIps=`curl -s  -m 15 metadata/self|grep '/ip'|awk '{print  $2}'|sort|uniq|egrep '([0-9]{1,3}\.){3}[0-9]{1,3}'`
         echo "View current allNodeIps vlaue:" $allIps
         ipArr=(${allIps// / })
         for  ip  in ${ipArr[@]}
         do
            echo "View current Iterate ip:" $ip
            local ret="ssh -p 16022 ${ip} `cat /etc/hosts |grep ${MY_IP}`"
            local hasMY_IP=${ret}|awk '{print $7"  "$8}'
            if [ "${hasMY_IP}" = "" ];then
              echo "add starting----" "$ADDED_NODES_HOSTS_DOMAIN"
              ssh -p 16022 ${ip} `echo "$ADDED_NODES_HOSTS_DOMAIN" |awk '{len=split($0,a," ");for(i=1;i<=len;i=i+2) print a[i]"\t"a[i+1] }'  >> /etc/hosts`
              local catRet="ssh -p 16022 ${ip} `cat /etc/hosts`"
              echo  "View  ip:" ${ip} "Node's /etc/hosts content：" ${catRet}
              echo "add ending----" "$ADDED_NODES_HOSTS_DOMAIN"
            fi
         done
       fi
       echo  "Need ADDED NODES HOSTS DOMAIN:" $ADDED_NODES_HOSTS_DOMAIN
       echo "View current ip："${MY_IP} "Node's /etc/hosts content：" `cat /etc/hosts`
       #去复制以前节点的证书
       if [ ! -f "/var/lib/etcd/ssl/etcd/ca.pem" ];then
          local ip=`echo "$HOSTS_DOMAIN_NAME"|awk '{print $1}'`
          echo  "Copy all certificate from " ${ip}
          scp -P 16022 -rp   ${ip}:/var/lib/etcd/ssl  /var/lib/etcd
          chown -R etcd:etcd  /var/lib/etcd/ssl
       fi
       echo  "Need ADDED NODES DOMAIN:" $ADDED_NODES_DOMAIN
       buildCluster "$ADDED_NODES_DOMAIN"
    else
       buildCluster "$ADDED_NODES"
    fi
  else
   prepareEtcdConfig
   if [ "$MY_ROLE" = "etcd-node" ];then
    chown -R etcd.etcd $workingDir #升级时不会调用initETCDenv所以在这里重新执行
   fi
    svc start
  fi
}

stop() {
  log "Etcd service is asked to stop ."
  svc stop
}

openTLS(){
    firstNode=`echo $STABLE_NODES|awk '{print $1}'`
    firstNodeSID=`echo ${firstNode%=*}`
    firstNodeIP=`echo ${firstNode#*=}`
    echo "firstNodeSID:$firstNodeSID" ",firstNodeIP:$firstNodeIP"
    etcdctlTemp=""
#    if [ $ETCDAUTH = "false" ] ;then
    etcdctlTemp="/opt/etcd/current/etcdctl"
#    else
#     etcdctlTemp="/opt/etcd/current/etcdctl --user="${ETCDDEFAULTUSER}:${ETCDDEFAULTPASSWD}
#    fi

    if [ $ENABLE_TLS = "true" ]; then
       configureDomainName
       if [ $MY_SID =  $firstNodeSID ]; then
           generateCertificate $1
           allnodelist=`${etcdctlTemp}   --endpoints=http://${firstNodeIP}:2379  member list |awk '{print $1,$3}'|sed s/,/""/g`
           local count=0
           local memberId=""
           set +e
           for var in $allnodelist;do
               if [ "$count" -eq "0" ] ;then
                 memberId=$var
               else
                 `${etcdctlTemp} \
                 --cert=/var/lib/etcd/ssl/etcd/client.pem \
                 --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                 --cacert=/var/lib/etcd/ssl/etcd/ca.pem \
                 --endpoints=http://${firstNodeIP}:2379  member update $memberId --peer-urls="https://${var}${ETCD_CLUSTER_DNS}:2380"`
               fi
               count=`expr $count + 1`
               if [ "$count" -eq "2" ]; then
                 count=0
               fi
           done
           set -e
       fi
       sleep 20
       #去复制以前节点的证书
       if [ ! -f "/var/lib/etcd/ssl/etcd/ca.pem" ];then
          local ip=`echo "$HOSTS_DOMAIN_NAME"|awk '{print $1}'`
          echo  "Copy all certificate from " ${ip}
          scp -P 16022 -rp   ${ip}:/var/lib/etcd/ssl  /var/lib/etcd
          chown -R etcd:etcd  /var/lib/etcd/ssl
       fi
       prepareEtcdConfig

       local allPeerAddrDomain="true"
       local sleepMaxTime=0
       while [ ${sleepMaxTime} -le 90 ]; do
          set +e
          sleepMaxTime=`expr ${sleepMaxTime} + 1`
          allPeerNode=`${etcdctlTemp}   --endpoints=http://${firstNodeIP}:2379  member list |awk '{print $4}'|sed s/,/""/g`
          if [ $? -ne 0 ]; then
              echo "openTLS  member list  view failed: ${sleepMaxTime} times"
              sleep 1
              continue
          fi
          echo "sleepMaxTime: $sleepMaxTime ,current member list info： $allPeerNode"
          for peerNode in $allPeerNode;do
            changeDomain=`echo $peerNode |grep ${ETCD_CLUSTER_DNS}`
            echo "member list  PEER ADDRS value:$changeDomain"
            if [[ "$changeDomain" = "" ]];then
              echo "Not all member addresses have been changed to domain names"
              allPeerAddrDomain="false"
              break
            fi
          done
          if [ "$allPeerAddrDomain" = "true" ]; then
              break
          fi
          sleep 1
          set -e
       done

       systemctl daemon-reload
       systemctl stop etcd
       systemctl start etcd
    fi

}

closeTLS(){
    firstNode=`echo $STABLE_NODES|awk '{print $1}'`
    firstNodeSID=`echo ${firstNode%=*}`
    firstNodeIP=`echo ${firstNode#*=}`
    echo "firstNodeSID:$firstNodeSID" ",firstNodeIP:$firstNodeIP"
    etcdctlTemp=""
#    if [ $ETCDAUTH = "false" ] ;then
    etcdctlTemp="/opt/etcd/current/etcdctl"
#    else
#     etcdctlTemp="/opt/etcd/current/etcdctl --user="${ETCDDEFAULTUSER}:${ETCDDEFAULTPASSWD}
#    fi

    if [ $ENABLE_TLS = "false" ]; then
       echo "close TLS starting!"
       if [ $MY_SID =  $firstNodeSID ]; then
           allnodelist=`${etcdctlTemp} \
                        --cert=/var/lib/etcd/ssl/etcd/client.pem  \
                        --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                        --cacert=/var/lib/etcd/ssl/etcd/ca.pem  \
                        --endpoints=https://etcd${firstNodeSID}${ETCD_CLUSTER_DNS}:2379  member list |awk '{print $1,$3}'|sed s/,/""/g`
           local count=0
           local memberId=""
           set +e
           for var in $allnodelist;do
               if [ "$count" -eq "0" ] ;then
                 memberId=$var
               else
                 local ip=`cat /etc/hosts|grep $var|awk '{print $1}'`
                 `${etcdctlTemp} \
                 --cert=/var/lib/etcd/ssl/etcd/client.pem \
                 --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                 --cacert=/var/lib/etcd/ssl/etcd/ca.pem \
                 --endpoints=https://${var}${ETCD_CLUSTER_DNS}:2379  member update $memberId --peer-urls="http://${ip}:2380"`
               fi
               count=`expr $count + 1`
               if [ "$count" -eq "2" ]; then
                 count=0
               fi
           done
           set -e
       fi
       echo "close TLS end!"
       sleep 20
       prepareEtcdConfig

       local allPeerAddrIP="true"
       local sleepMaxTime=0
       while [ ${sleepMaxTime} -le 90 ]; do
          set +e
          sleepMaxTime=`expr ${sleepMaxTime} + 1`
          allnodelist=`${etcdctlTemp} \
                        --cert=/var/lib/etcd/ssl/etcd/client.pem  \
                        --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                        --cacert=/var/lib/etcd/ssl/etcd/ca.pem  \
                        --endpoints=https://etcd${firstNodeSID}${ETCD_CLUSTER_DNS}:2379  member list |awk '{print $4}'|sed s/,/""/g`
          if [ $? -ne 0 ]; then
              echo "closeTLS  member list  view failed: ${sleepMaxTime} times"
              sleep 1
              continue
          fi
          echo "sleepMaxTime: $sleepMaxTime ,current member list info： $allnodelist"
          for peerNode in $allnodelist;do
            changeIP=`echo $peerNode |grep ${ETCD_CLUSTER_DNS}`
            echo "member list  PEER ADDRS value:$changeIP"
            if [[ "$changeIP" != "" ]];then
              echo "Not all member addresses have been changed to ip"
              allPeerAddrIP="false"
              break
            fi
          done
          if [ "$allPeerAddrIP" = "true" ]; then
              break
          fi
          sleep 1
          set -e
       done

       systemctl daemon-reload
       systemctl stop etcd
       systemctl start etcd
    fi

}

destroy() {
  if [ $ENABLE_TLS = "true" ]; then
     for node in $DELETED_NODES_DOMAIN; do
       local member="$(buildMember $node)"
       if [ "${node%=*}" != "$MY_SID" ]; then
         log "Waiting member $member to be removed ..."
         retry 200 1 checkMemberRemoved $member
       else
         local memberId="$(retry 10 1 findMemberId etcd${MY_SID}${ETCD_CLUSTER_DNS})"
         [ -n "$memberId" ] || return $EC_NO_MEMBER_ID
         log "Removing myself [$member] with ID [$memberId] from cluster ..."
         # This may fail some times until the cluster gets healthy again after removed some other members.
         retry 200 1 removeMember $memberId
         retry 10 1 checkStopped
         stop
         break
       fi
     done
  else
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
  fi
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
  snapshot_id=$(echo "$@" | jq -r '."snapshot_id"')
  echo "snapshot_id value:$snapshot_id"
  if [ "$snapshot_id" != "" ];then
    rm -rf /var/lib/etcd/ssl
  fi
  rm -rf $etcdDataDir && sleep 1 && initETCDenv
  prepareEtcdConfig
  if [ -f "$v3BackupFile" ]; then
    restoreSnap $v3BackupFile
    svc start
  else
    if [ $ENABLE_TLS = "true" ]; then
       local firstNode=${ALL_NODES_DOMAIN%% *}
       local firstNodeIp=${firstNode#*=}
       if [ "$firstNodeIp" = "etcd${MY_SID}${ETCD_CLUSTER_DNS}" ]; then
         [ -d "$v2BackupDir" ] || return $EC_RESTORE_NO_DB
         log "Restoring v2 on first node ..."
         mv $v2BackupDir $etcdDataDir
         log "Starting etcd restore service ..."
         systemctl start etcd-standalone
         log "Updating my peer url ..."
         sleep 3 #是为了等待etcd-standalone启动起来
         local myMemberId
         myMemberId=$(findMemberId localhost etcd${MY_SID}${ETCD_CLUSTER_DNS})
         retry 10 1 etcdctl  member update $myMemberId --peer-urls=$(buildMemberDomainUrls) || {
           systemctl stop etcd-standalone
           return $EC_RESTORE_ERROR
         }
         log "Stopping etcd restore service ..."
         systemctl stop etcd-standalone
       fi
       buildCluster "$ALL_NODES_DOMAIN"
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
         sleep 3 #是为了等待etcd-standalone启动起来
         local myMemberId
         myMemberId=$(findMemberId localhost $MY_IP)
         retry 10 1 etcdctl  member update $myMemberId --peer-urls=$(buildMemberUrls) || {
           systemctl stop etcd-standalone
           return $EC_RESTORE_ERROR
         }
         log "Stopping etcd restore service ..."
         systemctl stop etcd-standalone
       fi
       buildCluster "$ALL_NODES"
    fi
  fi
}

restart() {
  log "Etcd service is asked to restart ."
  stop && start
}

upgrade() {
  # 先升级至当前次版本号对应的最新修订版本号以规避升级bug，后升级至目标版本
  initETCDenv
   
  log "Etcd service is prepared to upgrade to $etcdVersion"
  local sleepMaxTime=0
  while :
  do
#     curl -L $(buildClientUrls)/version >>/root/a.txt || echo
     check && break || echo -n
     sleepMaxTime=`expr ${sleepMaxTime} + 1`
     if [ ${sleepMaxTime} -ge 60 ]; then
        return -1
     fi
     sleep 1s
  done 
  #stop
  #rm -rf /opt/etcd/current
  #ln -s /opt/etcd/$etcdVersion /opt/etcd/current
  
  #initETCDenv
  #curl -L $(buildClientUrls)/version >>/root/a.txt || echo
  #start
}

changesClusterDNS(){
    ETCD_CLUSTER_DNS_before=$1
    ETCD_CLUSTER_DNS_after=$2
    firstNode=`echo $STABLE_NODES|awk '{print $1}'`
    firstNodeSID=`echo ${firstNode%=*}`
    firstNodeIP=`echo ${firstNode#*=}`
    echo "firstNodeSID:$firstNodeSID" ",firstNodeIP:$firstNodeIP"
    etcdctlTemp=""
#    if [ $ETCDAUTH = "false" ] ;then
    etcdctlTemp="/opt/etcd/current/etcdctl"
#    else
#     etcdctlTemp="/opt/etcd/current/etcdctl --user="${ETCDDEFAULTUSER}:${ETCDDEFAULTPASSWD}
#    fi
    if [ "$MY_ROLE" = "etcd-node" ] && [ $ENABLE_TLS = "true" ] && [ "$IS_ADDED" != "true" ] ; then
       if [ $MY_SID =  $firstNodeSID ]; then
           #----生成新证书----
           local etcd_nodeAllIp='"'`curl -s -m 15   metadata/self/hosts/etcd_node/|grep /ip|grep -v eip|awk '{print $2}'|egrep '([0-9]{1,3}\.){3}[0-9]{1,3}'|sed ':label;N;s/\n/","/;b label'`'"'
            echo '{"CN":"CA","key":{"algo":"rsa","size":2048},"ca":{"expiry": "876000h"}}' | /usr/local/bin/cfssl gencert -initca - | /usr/local/bin/cfssljson -bare ca -
           echo '{"signing":{"default":{"expiry":"876000h"},"profiles":{"server":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]},"client":{"expiry":"876000h","usages":["signing","key encipherment","client auth"]},"peer":{"expiry":"876000h","usages":["signing","key encipherment","server auth","client auth"]}}}}' > ca-config.json
           export NAME=server
           echo '{"CN":"'$NAME'","hosts":["*'${ETCD_CLUSTER_DNS_after}'"],"key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -ca=ca.pem -ca-key=ca-key.pem -profile=server - | /usr/local/bin/cfssljson -bare $NAME
           export NAME=client
           echo '{"CN":"'$NAME'","key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -profile=client -ca=ca.pem -ca-key=ca-key.pem  - | /usr/local/bin/cfssljson -bare $NAME -
           export NAME=peer
           echo '{"CN":"'$NAME'","hosts":["*'${ETCD_CLUSTER_DNS_after}'"],"key":{"algo":"rsa","size":2048}}' | /usr/local/bin/cfssl gencert -config=ca-config.json -ca=ca.pem -ca-key=ca-key.pem -profile=peer - | /usr/local/bin/cfssljson -bare $NAME

           mkdir -p  /var/lib/etcd/ssl/etcdtemp/
           cp ./*.pem  /var/lib/etcd/ssl/etcdtemp/
           chown -R etcd:etcd  /var/lib/etcd/ssl/etcdtemp/

           allIps=`curl -s  -m 15 metadata/self|grep '/ip'|awk '{print  $2}'|sort|uniq|egrep '([0-9]{1,3}\.){3}[0-9]{1,3}'`
           ipArr=(${allIps// / })
           for  ip  in ${ipArr[@]}
           do
              echo "scp cert to ${ip}"
              if [ ${ip} != ${MY_IP} ];then
                scp -P 16022 -rp /var/lib/etcd/ssl/etcdtemp  ${ip}:/var/lib/etcd/ssl
                ssh -p 16022 ${ip} "chown -R etcd:etcd  /var/lib/etcd/ssl"
              fi
           done

           /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/caPem  "$(base64  <<< cat /var/lib/etcd/ssl/etcdtemp/ca.pem)"
           /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/clientPem   "$(base64  <<< cat /var/lib/etcd/ssl/etcdtemp/client.pem)"
           /opt/etcd/current/etcdctl   --endpoints=http://metadata:2379  put  /clusters/${CLUSTER_ID}/env/etcd_node/clientKeyPem "$(base64  <<< cat /var/lib/etcd/ssl/etcdtemp/client-key.pem)"

           #----生成新证书结束----

           #----修改etcd集群信息开始----
           allnodelist=`${etcdctlTemp} \
                       --cert=/var/lib/etcd/ssl/etcd/client.pem \
                       --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                       --cacert=/var/lib/etcd/ssl/etcd/ca.pem \
                       --endpoints=https://etcd${firstNodeSID}${ETCD_CLUSTER_DNS_before}:2379  member list |awk '{print $1,$3}'|sed s/,/""/g`
           local count=0
           local memberId=""
           set +e
           for var in $allnodelist;do
               if [ "$count" -eq "0" ] ;then
                 memberId=$var
               else
                 `${etcdctlTemp} \
                 --cert=/var/lib/etcd/ssl/etcd/client.pem \
                 --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                 --cacert=/var/lib/etcd/ssl/etcd/ca.pem \
                 --endpoints=https://etcd${firstNodeSID}${ETCD_CLUSTER_DNS_before}:2379  member update $memberId --peer-urls="https://${var}${ETCD_CLUSTER_DNS_after}:2380"`
               fi
               count=`expr $count + 1`
               if [ "$count" -eq "2" ]; then
                 count=0
               fi
           done
           set -e
           #----修改etcd集群信息结束----
       fi

       sleep 20
       #去复制以前节点的证书
       if [ ! -f "/var/lib/etcd/ssl/etcdtemp/ca.pem" ];then
          local ip=`echo "$HOSTS_DOMAIN_NAME"|awk '{print $1}'`
          echo  "Copy all certificate from " ${ip}
          scp -P 16022 -rp   ${ip}:/var/lib/etcd/ssl/  /var/lib/etcd/
          chown -R etcd:etcd  /var/lib/etcd/ssl
       fi
       cp -r  /var/lib/etcd/ssl/etcdtemp/* /var/lib/etcd/ssl/etcd
       prepareEtcdConfig

       local allPeerAddrChanged="true"
       local sleepMaxTime=0
       while [ ${sleepMaxTime} -le 90 ]; do
          set +e
          sleepMaxTime=`expr ${sleepMaxTime} + 1`
          allnodelist=`${etcdctlTemp} \
                        --cert=/var/lib/etcd/ssl/etcd/client.pem  \
                        --key=/var/lib/etcd/ssl/etcd/client-key.pem \
                        --cacert=/var/lib/etcd/ssl/etcd/ca.pem  \
                        --endpoints=https://etcd${firstNodeSID}${ETCD_CLUSTER_DNS_before}:2379  member list |awk '{print $4}'|sed s/,/""/g`
          if [ $? -ne 0 ]; then
              echo "changesClusterDNS  member list  view failed: ${sleepMaxTime} times"
              sleep 1
              continue
          fi
          echo "sleepMaxTime: $sleepMaxTime ,current member list info： $allnodelist"
          for peerNode in $allnodelist;do
            changeDomain=`echo $peerNode |grep ${ETCD_CLUSTER_DNS_after}`
            echo "member list  PEER ADDRS value:$changeDomain"
            if [[ "$changeDomain" = "" ]];then
              echo "Not all member addresses have been changed to new domain"
              allPeerAddrChanged="false"
              break
            fi
          done
          if [ "$allPeerAddrChanged" = "true" ]; then
              break
          fi
          set -e
       done

       systemctl daemon-reload
       systemctl stop etcd
       #删除以前的hosts域名配置
       sed -i "/${ETCD_CLUSTER_DNS_before}$/d" /etc/hosts
       rm -rf /var/lib/etcd/ssl/etcdtemp
       systemctl start etcd

    fi
}

update() {
  svc is-enabled -q || return 0
  [ "$MY_ROLE" = "etcd-proxy" ] || [[ ,${CHANGED_VARS// /,} =~ ,ETCD_ ]] || return 0
  local closeChangeOpenTLS=$(echo ${CHANGED_VARS} | grep "ETCD_ENABLE_TLS=false ETCD_ENABLE_TLS=true")
  local openChangeCloseTLS=$(echo ${CHANGED_VARS} | grep "ETCD_ENABLE_TLS=true ETCD_ENABLE_TLS=false")
  local changesClusterDNSTime=$(echo ${CHANGED_VARS}|grep -o "CLUSTER_DNS=*"|wc -l)
  if [[ "$closeChangeOpenTLS" != "" ]] && [[ "$changesClusterDNSTime" -ne "2" ]];then
      openTLS
  elif [[ "$openChangeCloseTLS" != "" ]];then
      closeTLS
  elif [[ "$changesClusterDNSTime" -eq "2" ]] && [[ "$closeChangeOpenTLS" = "" ]];then
      changesClusterDNS=""
      for var in ${CHANGED_VARS};do
        echo $var
        if [ ${var%=*} = "ETCD_CLUSTER_DNS" ];then
           changesClusterDNS="$changesClusterDNS ${var#*=}"
        fi
      done
      echo $changesClusterDNS
      changesClusterDNS $changesClusterDNS
  elif [[ "$changesClusterDNSTime" -eq "2" ]] && [[ "$closeChangeOpenTLS" != "" ]];then
      openTLSAndChangeDomain="true"
      openTLS $openTLSAndChangeDomain
      #删除以前hosts域名配置
      ClusterDNSBefore=""
      for var in ${CHANGED_VARS};do
        echo $var
        if [ ${var%=*} = "ETCD_CLUSTER_DNS" ];then
           ClusterDNSBefore="${var#*=}"
           break
        fi
      done
      sed -i "/${ClusterDNSBefore}$/d" /etc/hosts
  else
     restart
  fi
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
  sshPort=$(netstat -tunpl | grep $(ps -ef |grep `which sshd` | grep -v grep | awk '{print $2}') | grep -v tcp6 | awk '{print $4}' | awk -F ':' '{print $2}')

  if [ "$sourceIp" = "$MY_IP" ]; then
    backup

    for node in $ALL_NODES; do
      local ip=${node#*=}
      log "Notifying node on $ip ..."
      [ "$ip" = "$MY_IP" ] || ssh -p $sshPort $ip "touch $ready2Copy"
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
      [ "$firstNodeIp" = "$MY_IP" ] || scp -P $sshPort -r $v2BackupDir $firstNodeIp:$v2BackupDir
    else
      for node in $ALL_NODES; do
        local ip=${node#*=}
        [ "$ip" = "$MY_IP" ] || scp -P $sshPort $v3BackupFile $ip:$v3BackupFile
      done
    fi

    for node in $ALL_NODES; do
      local ip=${node#*=}
      [ "$ip" = "$MY_IP" ] || ssh -p $sshPort $ip "touch $ready2Start"
    done
  else
    retry 20 1 checkFileReady $ready2Copy
    stop
    rm -rf $v2BackupDir $v3BackupFile*
    ssh -p $sshPort $sourceIp "touch $ready2Copy-$MY_IP"
    retry 200 1 checkFileReady $ready2Start
  fi

  restore
}

repairMinorityNode(){
   healthNodeIP=$(echo "$@" | jq -r '."healthnode.ip"')
   unHealthNodeIP=$(echo "$@" | jq -r '."unhealthnode.ip"')

   local unHealthNodeStatus=""
   local  healthNodeStatus=""
   healthNode="http://${healthNodeIP}:2379"
   if [ $ENABLE_TLS = "true" ]; then
      unHealthNodeStatus="$(curl -s  --cacert /var/lib/etcd/ssl/etcd/ca.pem  --cert  /var/lib/etcd/ssl/etcd/client.pem   --key  /var/lib/etcd/ssl/etcd/client-key.pem $(buildClientDomainUrls)/health | jq -r '.health')"
      IPkey=`curl -s metadata/self|grep $healthNodeIP|awk '{print $1}'|grep -v /env/hostsDomain  |grep -v /host/ip |grep -v /cmd`
      sid=`curl -s metadata/self|grep ${IPkey%/*}/sid|awk '{print $2}'`
      clusterDNS=`curl -s metadata/self|grep /env/cluster_DNS|awk '{print $2}'`
      healthNode="https://etcd${sid}${clusterDNS}:2379"
      healthNodeStatus="$(curl -s  --cacert /var/lib/etcd/ssl/etcd/ca.pem  --cert  /var/lib/etcd/ssl/etcd/client.pem   --key  /var/lib/etcd/ssl/etcd/client-key.pem ${healthNode}/health | jq -r '.health')"
   else
      unHealthNodeStatus="$(curl -s $(buildClientUrls)/health | jq -r '.health')"
      healthNodeStatus="$(curl -s ${healthNode}/health | jq -r '.health')"
   fi

   #输入的不健康节点是当前节点，当前节点是不健康状态,且输入的健康节点是健康才执行。
   if  [ "$unHealthNodeIP" = "$MY_IP" ] && [ "$unHealthNodeStatus" != "true" ] && [ "$healthNodeStatus" = "true" ];then
      stopNodeEtcdService
      removeNodeAndaddNodeAgain $healthNode
      modifyCfgAndRestart $healthNode
      verifyClusterHealth
      machineEnvRecovery
   else
      return 0
   fi
}

updateEtcdAuthCtl(){
  updateEtcdAuth
}

updateEtcdPasswdCtl(){
  updateEtcdPasswd
}


getAccessCertificate(){
  if [ $ENABLE_TLS = "true" ]; then
     hostsDomain=`cat /etc/hosts|grep ${ETCD_CLUSTER_DNS}| jq -Rsc  "."`
     caPem=`cat /var/lib/etcd/ssl/etcd/ca.pem| jq -Rsc  "."`
     clientPem=`cat /var/lib/etcd/ssl/etcd/client.pem| jq -Rsc  "."`
     clientKeyPem=`cat /var/lib/etcd/ssl/etcd/client-key.pem| jq -Rsc  "."`
     echo '{"labels": ["hostsDomain","ca.pem","client.pem","client-key.pem"], "data": [['$hostsDomain','$caPem','$clientPem','$clientKeyPem']]}'|jq  "."
  else
     echo '{"labels": ["hostsDomain","ca.pem","client.pem","client-key.pem"], "data": [["","","",""]]}'|jq  "."
  fi
}


$command $args
