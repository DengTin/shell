#!/bin/bash

readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"
readonly cfg="$base_dir/$base_name.cfg"
readonly db_list=$(cat $cfg | sed '/^\s*$/d' |awk 'BEGIN {ORS = " "} {if($1 !~/^#/) print $0}'| sed -e 's/[ \t]*$//')
readonly nc_default="nc"
readonly nc_custom="/opt/IBM/tools/tivoli/nc"
readonly sqlplus_path="/opt/oracle/instantclient_11_2/sqlplus"

function make_file() {
  if [ ! -f "$1" ]; then
    touch "$1" 2>/dev/null
    chmod 777 "$1" 2>/dev/null
  fi
}

#param1: command
function is_command() {
  local result=$(whereis $1 | awk -F ":" '{print $2}' | sed '/^\s*$/d')
  if [[ "$result" == "" ]]; then
    echo -1
  else
    echo 0
  fi
}

#param1: ip address
function ping_test() {
  local result=$(ping -c 1 -W 1 $1 2>/dev/null| awk 'match($0, /[0-9]+% packet loss/) {print substr($0, RSTART, index($0, "%")-RSTART)}')
  if [[ "$result" =~ "unknown" ]] || [[ "$result" == "" ]]; then
    echo -1
  else
    echo $result
  fi
}

#param1: host
#param2: port
#param3: nc path
function tcp_test() {
  local result=$($3 -zw5 $1 $2)
  if [[ "$result" == *"succeeded"* ]]; then
    echo 0
  else
    echo -1
  fi
}

#param1: db instance
#param2: db username
#param3: db password
function db_conn_test {
  local result=$(echo "exit" | $sqlplus_path -L $2/$3@$1 | grep -i connected)
  if [[ "$result" == *"connected"* ]]; then
    echo 0
  else
    echo -1
  fi
}

function main() {
  $(make_file "$cfg")
  
  local nc_path=$nc_default
  if (( $(is_command $nc_default) != 0 )); then
    nc_path=$nc_custom 
  fi
  
  local json_str="";
  local tcp_status=""
  local auth_status=""
  local timestamp="$(date +"%F %T:%3N")"
  
  if [[ "$db_list" == "" ]]; then
    echo "{\"DB\":[]}"
    return 0
  fi
  
  for db in ${db_list[*]}; do
    local label=$(echo $db| awk  -F ';' '{print $1}')
    local host=$(echo $db| awk  -F ';' '{print $2}')
    local port=$(echo $db| awk  -F ';' '{print $3}')
    local instance=$(echo $db| awk  -F ';' '{print $4}')
    local username=$(echo $db| awk  -F ';' '{print $5}')
    local password=$(echo $db| awk  -F ';' '{print $6}')
    
    if [[ "$host" == "" || "$port" == "" ]]; then
      continue
    fi
    
    local result=$(tcp_test $host $port $nc_path)
    if (( $result == 0 )); then
      tcp_status="succeeded"
    else
      tcp_status="failed"
    fi
    
    if [[ "$tcp_status" == "failed" || "$instance" == "" || "$username" == "" || "$password" == "" ]]; then
      auth_status="unknown"
    else  
      result=$(db_conn_test $instance $username $password)
      if (( $result == 0 )); then
        auth_status="succeeded"
      else
        auth_status="failed"
      fi  
    fi  
    
    json_str=$json_str"{\"label\":\"$label\",\"host\":\"$host\",\"port\":\"$port\",\"timestamp\":\"$timestamp\",\"instance\":\"$instance\",\"username\":\"$username\",\"tcp_status\":\"$tcp_status\",\"auth_status\":\"$auth_status\"},"
  done
  
  json_str="{\"DB\":["$(echo $json_str | sed 's\,$\\g')"]}"  
  echo $json_str
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi