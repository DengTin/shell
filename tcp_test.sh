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
# 5M*2
readonly log_limit="5242880"
readonly log_size="2"
readonly log_info=" Info "
readonly log_error=" Error "
readonly log_warn=" Warning "

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
  $(make_dir "$log_dir")
  $(make_file "$first_log")
  
  local host="10.146.4.34"
  local port="10001"
  local nc_dir="/opt/IBM/tools/tivoli/nc"

  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "tcp test started" >> $first_log
  local result=$($nc_dir -zw10 $host $port)
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "tcp test finished: $result" >> $first_log
  
  local size=$(get_filesize "$first_log")
  if [[ "$size" -gt "$log_limit" ]]; then
    $(roll_log)
  fi
}

while (true); do
  $(main)
  sleep 1m
done