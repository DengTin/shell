#!/bin/bash

readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"
readonly cfg="$base_dir/$base_name.cfg"
readonly log_dir="$base_dir/logs"
readonly log_name="$log_dir/$base_name.log"
readonly first_log="$log_name"".0"
# 5M * 2
readonly log_limit="5242880"
readonly log_size="2"
readonly log_info=" Info "
readonly log_error=" Error "
readonly log_warn=" Warning "
readonly log_debug=" Debug "

function is_dir() {
  if [ -d "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

function is_file() {
  if [ -f "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

function make_dir() {
  if [ ! -d "$1" ]; then
    mkdir -pm 755 "$1"
  fi
}

function make_file() {
  if [ ! -f "$1" ]; then
    touch "$1"
    chmod 744 "$1"
  fi
}

function get_filesize() {
  local size=$(stat -c%s "$1")
  echo "$size"
}

# roll logs if exceeded limit size
function roll_log() {
  local j=$(( $log_size-1 ))

  for ((i=$j; i>0; i--)); do
    if [ $(is_file "$log_name"".""$(( $i-1 ))") -eq 0 ]; then
      mv $log_name"."$(( $i-1 )) $log_name"."$i
    fi
  done
}

function main() {
  #$(make_dir "$log_dir")
  #$(make_file "$first_log")

  local result=$(top -bn 1|sed '1,7d'|sort -nrk 9|head -3|awk 'BEGIN{ORS="__";} {print$9,$10,$1,$2}')
  local pids=$(echo $result | awk 'BEGIN{RS="__";ORS=" "} {print $3}')

  local i=1
  local proc_name=""
  local proc_cpu=-1
  local timestamp="$(date +"%F %T:%3N")"
  local cpu_total=$(sar -u 1 1 | awk '{if($1 ~/Average/) print substr($NF,1,length($NF)-3)}')
  cpu_total=$((100 - cpu_total))
  local cpu_json="{\"CPU\":[{\"name\":\"total\",\"id\":\"-1\",\"cpu\":\"$cpu_total%\",\"timestamp\":\"$timestamp\"},"
  
  for pid in ${pids[*]}; do
    if [[ "$pid" != "" ]]; then
      proc_cpu=$(echo $result | awk -v cnt="$i" 'BEGIN{RS="__";ORS=""} NR==cnt{print $1}')
      proc_name=$(ps -p $pid -f|sed 1d|awk '{if($0 != "") {print $8"--"$NF}}')
      if [[ "$proc_name" == "" ]]; then
        proc_name="Null"
      fi
      cpu_json=$cpu_json"{\"name\":\"$proc_name\",\"id\":\"$pid\",\"cpu\":\"$proc_cpu%\",\"timestamp\":\"$timestamp\"},"
    fi
    i=$((i+1))
  done
  
  cpu_json=$(echo $cpu_json | sed 's\,$\\g')"]}"

  #printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "$cpu_json" >> $first_log
  
  #local size=$(get_filesize "$first_log")
  #if [[ "$size" -gt "$log_limit" ]]; then
  #  $(roll_log)
  #fi
  
  echo $cpu_json
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi