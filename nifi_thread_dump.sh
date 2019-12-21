#!/bin/sh
readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"
readonly cfg="$base_dir/$base_name.cfg"
readonly log_dir="$base_dir/logs"
readonly log_name="$log_dir/$base_name.log"
readonly first_log="$log_name"".0"
readonly log_limit="20971520"
readonly log_size="10"

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
      cp $log_name"."$(( $i-1 )) $log_name"."$i
    fi
  done

  truncate $log_name".0" --size 0
}

$(make_dir "$log_dir")
$(make_file "$first_log")

while (true); do
  pid=$(ps -ef|grep -i nifi-properties|grep -v grep|awk '{print $2}')\
  if [[ "$pid" == "" ]]; then
    sleep 1m
    continue
  fi
  jstack -l $pid 2>/dev/null >> $first_log
  size=$(get_filesize "$first_log")
  if [[ "$size" -gt "$log_limit" ]]; then
    $(roll_log)
  fi
  sleep 1m
done
