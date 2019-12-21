#!/bin/bash

readonly log="/opt/IBM/tools/tivoli/logs/nifi_demons.log.0"

readonly gap=360

function is_file() {
  if [ -f "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

function main() {
  if (( $(is_file $log) != 0 )); then
    echo "{\"Nifi\":{}}"
    return 0
  fi
  
  local now_time=$(date +%s)
  local log_time=$(date +%s -r $log)
  local result=""
  local json="{\"Nifi\":"

  if (( $now_time-$log_time < $gap )); then
    result=$(cat $log | grep -i "group.*details" | tail -1 | awk '{for(i=7; i<=NF; i++) {str=str" "$i}; print str}' | sed 's/^ //g')
    if [[ "$result" == "" ]]; then
      result="{}"
    fi
    json=$json$result"}"
  else
    json=$json"{}}"
  fi

  echo $json
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi