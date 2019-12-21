#!/bin/bash

function display_q_t() {
  $(echo "DISPLAY $1(*) TYPE($2)" | $4/runmqsc $3 | grep -i "$1(" | grep -viE "$1\(system|grep" | awk '{ start=index($1,"(")+1; end=index($1,")")-start ; print substr($1, start, end) }' | sed '/^\s*$/d' > $3_$1_$2.txt)
}

function display_qmgrs() {
  qmgrs=$($1/dspmq | awk 'BEGIN {ORS=" "} { start=index($1,"(")+1; end=index($1,")")-start ; print substr($1, start, end) }' | sed '/^\s*$/d')
  echo $qmgrs
}

function main() {
  local mq_home="/opt/IBM/wmq/bin"

  local qmgrs=$(display_qmgrs $mq_home)
  
  for qmgr in ${qmgrs[*]}; do
    $(display_q_t queue qlocal $qmgr $mq_home)
    $(display_q_t queue qmodel $qmgr $mq_home)
    $(display_q_t queue qalias $qmgr $mq_home)
    $(display_q_t queue qremote $qmgr $mq_home)
    $(display_q_t queue qcluster $qmgr $mq_home)
    
    $(display_q_t topic cluster $qmgr $mq_home)
    $(display_q_t topic local $qmgr $mq_home)
    
    tar -cvf $qmgr_queues_topics.tar $qmgr*.txt
  done

  #$(echo "DISPLAY QLOCAL(*)" | $mq_home/runmqsc $qmgr | grep -i "queue(" | grep -viE "queue\(system|grep" | awk '{ start=index($1,"(")+1; end=index($1,")")-start ; print substr($1, start, end) }' | sed '/^\s*$/d' > $qmgr"_LQ.txt")
}

$(main)