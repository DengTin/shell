#!/bin/bash
# awk '{if($1 ~/^\[/ && $6 == "E") {gsub(/:$/,"",$7); err[$7]++; total++}} END{if(total != 0) print "total:"total; for(var in err) print var":"err[var]}' | sort -t ":" -nrk 2 | head -4 | awk 'BEGIN{ORS=" ";} {print $0}' | sed 's/ $//g'

readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"
readonly cfg="$base_dir/$base_name.cfg"
readonly item_list=$(cat $cfg | sed '/^\s*$/d' |awk 'BEGIN {ORS = " "} {if($1 !~/^#/) print $0}'| sed -e 's/[ \t]*$//')

function make_file() {
  if [ ! -f "$1" ]; then
    touch "$1" 2>/dev/null
    chmod 777 "$1" 2>/dev/null
  fi
}

function is_file() {
  if [ -f "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

# param1: log path
function get_exception() {
  local result=$(cat $1 | awk '{if($1 ~/^\[/ && ($6 == "E" || $6 == "SEVERE" || $6 == "ERROR")) {gsub(/:$/,"",$7); err[$7]++; total++}} END{if(total != 0) print "total:"total; for(var in err) print var":"err[var]}' | sort -t ":" -nrk 2 | head -4 | awk 'BEGIN{ORS=" ";} {print $0}' | sed 's/ $//g')
  
  echo $result
}

function main() {
  $(make_file "$cfg")
  
  local json_str="";
  local cnt=0
  local timestamp="$(date +"%F %T:%3N")"
  
  if [[ "$item_list" == "" ]]; then
    echo "{\"LOG\":[]}"
    return 0
  fi
  
  for item in ${item_list[*]}; do
    local label=$(echo $item| awk  -F ';' '{print $1}')
    local log_path=$(echo $item| awk  -F ';' '{print $2}')
    
    if [[ "$label" == "" || "$log_path" == "" ]]; then
      continue
    fi
    
    if (( $(is_file $log_path) == -1 )); then
      continue
    fi
    
    local exception_list=$(get_exception $log_path)
    json_str=$json_str"{\"label\":\"$label\",\"timestamp\":\"$timestamp\",\"exceptions\":["
    local i=0
    for exception in ${exception_list[*]}; do
      local key=$(echo $exception| awk  -F ':' '{print $1}')
      local value=$(echo $exception| awk  -F ':' '{print $2}')
      json_str=$json_str"{\"key\":\"$key\",\"value\":\"$value\"},"
      i=$((i+1))
    done
    
    json_str=$(echo $json_str | sed 's\,$\\g')"]},"
  done
  
  json_str="{\"LOG\":["$(echo $json_str | sed 's\,$\\g')"]}"  
  echo $json_str
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi