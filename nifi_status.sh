#!/bin/bash

readonly nifi_demons_log="/opt/IBM/tools/tivoli/logs/nifi_demons.log.0"
readonly gap=360

function main(){
  now_time=$(date +%s)
  log_time=$(date +%s -r $nifi_demons_log)
  if (( $now_time-$log_time < $gap )); then
    local str=$(cat $nifi_demons_log| awk '{if($3 == "Error") print $0}' | tail -1)
    if [[ "$str" == "" ]]; then
      return 0
    fi
    local date_str=$(echo "$str" | awk '{print $1,substr($2,1,8)}')
    local date_seconds=$(date -d "$date_str" +%s)
    local error_str=$(echo "$str" | awk '{ str=$1" "substr($2,1,8); for(i=5; i<NF; i++) {str=str" "$i}; print str}')
    if ((  $now_time-$date_seconds < $gap )); then
      echo "Nifi_Alert|"`date +%Y-%m-%d" "%k:%M:%S`"|$error_str"
    fi
  else
    echo "Nifi_Alert|"`date +%Y-%m-%d" "%k:%M:%S`"|Nifi demons log hasn't been modified more than $gap seconds"
  fi
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi