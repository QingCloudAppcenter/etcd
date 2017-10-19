#!/bin/bash

lines=$(cat /var/lib/etcd/coredns/Corefile | wc -l)

if [[ $lines -ne 0 ]]
then
  systemctl restart coredns
fi
