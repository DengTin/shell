#!/bin/bash
# Used to monitor Apache Nifi status
# Author:Joey Deng(dengtin@hotmail.com)
# cat logs/nifi_demons.log.0 | grep -i "group.*details" | tail -1 | awk '{for(i=7; i<=NF; i++) {str=str" "$i}; print str}' | sed 's/^ //g'

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

# get global variables from .cfg file
readonly nifi_debug=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_debug/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_home=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_home/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly root_group_id=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^root_group_id/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_cert_p12=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_cert_p12/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_cert_pem=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_cert_pem/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_cert_in_password=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_cert_in_password/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_py=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_py/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_host=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_host/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly nifi_ssl_port=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^nifi_ssl_port/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly max_queue_depth=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^max_queue_depth/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly min_running_cnt=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^min_running_cnt/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly max_cpu=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^max_cpu/) print $2}' | sed -e 's/[ \t\/]*$//')

function is_dir() {
  if [ -d "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

function is_dir_null() {
  local f=$(find "$1" -mindepth 1 -print -quit 2>/dev/null)
  if [[ "$f" == ""  ]]; then
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
    mkdir -pm 777 "$1" 2>/dev/null
  fi
}

function make_file() {
  if [ ! -f "$1" ]; then
    touch "$1" 2>/dev/null
    chmod 777 "$1" 2>/dev/null
  fi
}

# join the directory and the file name
# param1:directory name
# param2:file name
function path_join() {
  if [[ "$1" =~ \/$ ]]; then
    echo "$1$2"
  else
    echo "$1/$2"
  fi
}

# get file size in "block" unit
# param1:file name with absolute path
# return:file size in "block" unit
function get_filesize() {
  local size=$(stat -c %s "$1")
  echo "$size"
}

function is_num() {
  local re='^-?[0-9]+([.][0-9]+)?$'
  if ! [[ $1 =~ $re ]] ; then
    echo -1
  else
    echo 0
  fi
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

# test if the webservice was available
# param1:url string
# return:0 if success, -1 if failed
function test_connectivity() {
  local code=$(curl -sL -w "%{http_code}" "$1" -o /dev/null)
  if [ "$code" -eq "000" ]; then
    echo -1
  else
    echo 0
  fi
}

# param1: process name string
function get_pid() {
  echo "$(ps -ef|grep -i $1|grep -v grep| awk '{print $2}')"
}

# param1: process id
function get_proc_cpu() {
  echo "$(ps -p $1 -o %cpu|awk '{if ($1 ~/[0-9]/) print substr($1, 1, index($1, ".")-1)}')"
}

# preparation work
function init(){
  $(make_dir "$log_dir")
  $(make_file "$first_log")
  $(make_file "$cfg")
  
  local size=$(get_filesize "$first_log")
  if [[ "$size" -gt "$log_limit" ]]; then
    $(roll_log)
  fi

  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "initialized" >> $first_log
}

# convert .p12 cert file to .pem cert file
function p12_2_pem() {
  if [[ "$(is_file $nifi_cert_pem)" == "0" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} ".pem cert already exist" >> $first_log
    return 0
  fi
  
  if [[ "$nifi_cert_in_password" != "" ]]; then
    openssl pkcs12 -passin pass:$nifi_cert_in_password -in $nifi_cert_p12 -out $nifi_cert_pem -nodes
  else
    openssl pkcs12 -in $nifi_cert_p12 -out $nifi_cert_pem -nodes
  fi
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} ".pem cert generating finished" >> $first_log
}

# check if the .cfg file for Nifi is configured correctly
# return:0 if normal, -1 if error
function pre_check() {
  local items=("nifi_cert_pem" "nifi_cert_in_password" "root_group_id" "nifi_host" "nifi_debug" "nifi_ssl_port" "max_queue_depth" "min_running_cnt" "max_cpu" "nifi_cert_p12" "nifi_home" "nifi_py")
  local values=($nifi_cert_pem $nifi_cert_in_password $root_group_id $nifi_host $nifi_debug $nifi_ssl_port $max_queue_depth $min_running_cnt $max_cpu $nifi_cert_p12 $nifi_home $nifi_py)
  local i=0
  local has_error=false
  
  for item in ${items[*]}; do
    i=$((i+1))
    if [[ "${values[i-1]}" == "" ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "$item not set" >> $first_log
      has_error=true
    fi
    
    if [[ "$item" == "nifi_home" ]]; then
      if [[ "$(is_dir ${values[i-1]})" != "0" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "directory ${values[i-1]} not exist" >> $first_log
        has_error=true
      fi
    fi
    
    if [[ "$item" == "nifi_cert_p12" || "$item" == "nifi_py" ]]; then
      if [[ "$(is_file ${values[i-1]})" != "0" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "file ${values[i-1]} not exist" >> $first_log
        has_error=true
      fi
    fi
    
    if [[ "$item" == "nifi_ssl_port" || "$item" == "max_queue_depth" || "$item" == "min_running_cnt" || "$item" == "max_cpu" ]]; then
      if [[ "$(is_num ${values[i-1]})" != "0" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "$item: ${values[i-1]} not a digit" >> $first_log
        has_error=true
      fi
    fi    
  done
  
  if [[ $has_error == true ]]; then
    echo -1
    return 0
  fi
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "nifi demons configured correctly" >> $first_log
  echo 0
}

# update processor status
# param1:processor_id
# param2:revision
# param3:status, e.g, "RUNNING", "STOPPED"
function put_processor() {
  local json_str="{\"revision\":$2,\"status\":{\"runStatus\":\"$3\"},\"component\":{\"id\":\"$1\",\"state\":\"$3\"},\"id\":\"$1\"}"
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "json_str: $json_str" >> $first_log
  fi
  
  local result=$(curl -k -E $nifi_cert_pem -i -H 'Content-Type:application/json' -sX PUT -d $json_str https://$nifi_host:$nifi_ssl_port/nifi-api/processors/$1 | grep -i "http")
  
  if [[ $result =~ .*HTTP.*200.* ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "update processor: $1 to $3 successful" >> $first_log
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "update processor: $1 to $3 failed" >> $first_log
  fi
}

# update all state in a process group, powerful
# param1: group id
# param2: status, e.g, "RUNNING", "STOPPED"
function put_group() {
  local json_str="{\"id\":\"$1\",\"state\":\"$2\"}"
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "json_str: $json_str" >> $first_log
  fi
  
  local result=$(curl -k -E $nifi_cert_pem -i -H 'Content-Type:application/json' -sX PUT -d $json_str https://$nifi_host:$nifi_ssl_port/nifi-api/flow/process-groups/$1 | grep -i "http")
  
  if [[ $result =~ .*HTTP.*200.* ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "update group: $1 to $2 successful" >> $first_log
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "update group: $1 to $2 failed" >> $first_log
  fi
}

# update remote process group port status
# param1: remote process group id
# param2: revision
# param3: boolean, e.g, "true", "false"
# param4: remote process group input port id

function put_rpg_port() {
  local json_str="{\"revision\":$2,\"remoteProcessGroupPort\":{\"id\":\"$4\",\"groupId\":\"$1\",\"transmitting\":$3}}"
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "json_str: $json_str" >> $first_log
  fi
  
  local result=$(curl -k -E $nifi_cert_pem -i -H 'Content-Type:application/json' -sX PUT -d $json_str https://$nifi_host:$nifi_ssl_port/nifi-api/remote-process-groups/$1/input-ports/$4 | grep -i "http")
  
  if [[ $result =~ .*HTTP.*200.* ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "update remote process group port: $4 to $3 successful" >> $first_log
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "update remote process group port: $4 to $3 failed" >> $first_log
  fi
}

# get processors in group
# param1:group_id
function get_pg_procs() {
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local processors=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/process-groups/$1/processors | python $nifi_py processors | awk -F ';' 'BEGIN { ORS=" "} {print $0}' | sed '/^\s*$/d')
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "processors in group $1: $processors" >> $first_log
  fi
  
  echo "$processors"
}

# get sub process-groups in group
# param1: process group id
function get_pg_pg(){
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local groups=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/process-groups/$1/process-groups | python $nifi_py processGroups | awk -F ';' 'BEGIN { ORS=" "} {print $0}' | sed '/^\s*$/d')
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "groups in group $1: $groups" >> $first_log
  fi
  
  echo "$groups"
}

# get group details
# param1: group id
# return: json string
function get_pg_details(){
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local group_details=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/process-groups/$1 | python $nifi_py rootGroup | sed '/^\s*$/d')
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "group details: $group_details" >> $first_log
  
  echo "$group_details"
}

# get remote-process-groups in group
# param1:group id
function get_pg_rpg() {
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local rpg=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/process-groups/$1/remote-process-groups | python $nifi_py remoteProcessGroups | awk -F ';' 'BEGIN { ORS=" "} {print $0}' | sed '/^\s*$/d')
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "remote process groups in group $1: $rpg" >> $first_log
  fi
  
  echo "$rpg"
}

# get a remote-process-group's details
# param1: remote process group id
function get_rpg() {
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local rpg=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/remote-process-groups/$1 | python $nifi_py rpgPorts | awk -F ';' 'BEGIN { ORS=" "} {print $0}' | sed '/^\s*$/d')
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "remote process groups: $rpg" >> $first_log
  fi
  
  echo "$rpg"
}

# get queue depth in all connections in a group
# param1:process group id
function get_connections() {
  # the python script expects 6 kind parameters: processors, processGroups, remoteProcessGroups, rpgPorts, connections, rootGroup
  local connections=$(curl -k -E $nifi_cert_pem -sX GET https://$nifi_host:$nifi_ssl_port/nifi-api/process-groups/$1/connections | python $nifi_py connections | awk -F ';' 'BEGIN { ORS=" "} {print $0}' | sed '/^\s*$/d')
  
  if [[ "$nifi_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "connections in process group: $connections" >> $first_log
  fi
  
  echo "$connections"
}

# check connections in group
# param1:group id
function conn_pg_check {
  local connections=$(get_connections $1)
  connections=$(echo "$connections" | awk -v max=$max_queue_depth -F ";" 'BEGIN {RS=" "; ORS=" "} {if(substr($5,index($5,":")+1)+0 >= max+0)  print $0}' | sed '/^\s*$/d')
    
  if [[ "$connections" != "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "queue depth more than $max_queue_depth: $connections" >> $first_log
    
    # if messages stuck in queue and destination is a remote process group, then restart it
    for var in ${connections[*]}; do
      local destination_id=$(echo $var | awk -F ';' '{print substr($3,index($3,":")+1)}')
      local destination_name=$(echo $var | awk -F ';' '{print substr($4,index($4,":")+1)}')
      local destination_type=$(echo $var | awk -F ';' '{print substr($7,index($7,":")+1)}')
      local destination_group_id=$(echo $var | awk -F ';' '{print substr($6,index($6,":")+1)}')
      if [[ "$destination_type" != "REMOTE_INPUT_PORT" ]]; then
        continue
      fi
      local rpg_port=$(get_rpg $destination_group_id)
      local revision=$(echo $rpg_port | awk -F ';' '{print substr($4,index($4,":")+1)}')
      $(put_rpg_port $destination_group_id $revision "false" $destination_id)
      $(put_rpg_port $destination_group_id $revision "true" $destination_id)
      
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "restarted $destination_name in remote processo group" >> $first_log
    done    
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "queue depth in connections less than $max_queue_depth or no connections in group: $1" >> $first_log
  fi
}

# check processors in group
# param1: group id
function procs_pg_check {
  local processors=$(get_pg_procs $1)
  processors=$(echo "$processors" | awk -F ";" 'BEGIN {RS=" "; ORS=" "} {if($NF !~/RUNNING$/) print $0}' | sed '/^\s*$/d')
    
  if [[ "$processors" != "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "processors status abnormal: $processors" >> $first_log
    processors=( $processors )
    
    for var in ${processors[*]}; do
      local processor_id=$(echo $var | awk -F ';' '{print substr($1,index($1,":")+1)}')
      local revision=$(echo $var | awk -F ';' '{print substr($3,index($3,":")+1)}')
      $(put_processor $processor_id $revision "RUNNING")
    done
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "processors are running or no processors in group: $1" >> $first_log
  fi
}

# check remote-process-groups in group
# param1: group id
function rpg_pg_check {
  local rpg=$(get_pg_rpg $1)
  rpg=$(echo "$rpg" | awk -F ";" 'BEGIN {RS=" "; ORS=" "} {{if(substr($3,index($3,":")+1) != "true" || substr($4,index($4,":")+1) == "0") print $0}}' | sed '/^\s*$/d')
  
  if [[ "$rpg" != "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "remote process groups status abnormal: $rpg" >> $first_log
    rpg=( $rpg )
    for var in ${rpg[*]}; do
      local rpg_id=$(echo $var | awk -F ';' '{print substr($1,index($1,":")+1)}')
      local rpg_ports=$(get_rpg $rpg_id)
      
      if [[ "$rpg_ports" == "" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "no active remote input port in remote process group: $rpg_id" >> $first_log
        continue
      fi
      local revision=$(echo $rpg_ports | awk -F ';' '{print substr($4,index($4,":")+1)}')
      local port_id=$(echo $rpg_ports | awk -F ';' '{print substr($1,index($1,":")+1)}')
      $(put_rpg_port $rpg_id $revision "true" $port_id)
    done
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "remote process groups status OK or none in group: $1" >> $first_log
  fi
}

# check everything in nifi group
# param1:group id
function group_check() {
  local groups
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "start checking group: $1" >> $first_log
  
  # check processors in the process group
  $(procs_pg_check $1)
  # check remote-process-groups in the process group
  $(rpg_pg_check $1)
  # check connections in the process group
  $(conn_pg_check $1)
    
  groups=$(get_pg_pg $1)
  groups=$(echo "$groups" | awk -v max=$max_queue_depth  -F ";" 'BEGIN {RS=" "; ORS=" "} {{if(substr($3,index($3,":")+1) != "0" || substr($4,index($4,":")+1) != "0" || substr($5,index($5,":")+1) != "0" || substr($6,index($6,":")+1) != "0" || substr($7,index($7,":")+1)+0 >= max+0) print $0}}' | sed '/^\s*$/d')
  
  # if sub group is OK, then stop, else check recursively
  if [[ "$groups" != "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "sub groups status abnormal: $groups" >> $first_log
    groups=( $groups )
    for var in ${groups[*]}; do
      local group_id=$(echo $var | awk -F ';' '{print substr($1,index($1,":")+1)}')
      $(group_check $group_id)
    done
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "sub groups are OK or no sub groups in group: $1" >> $first_log
  fi
}

# check the running count in process group details
# param1: process group id
function pg_details_check(){
  local group_details=$(get_pg_details $1)
  if [[ "$group_details" == "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "group $1 didn't exist or not available" >> $first_log
    echo -1
    return 0
  fi
  
  local running_cnt=$(echo "$group_details" | awk -F "," '{for(i=1; i<=NF; i++) if($i ~/runningCount/) print substr($i,index($i,":")+1)}' | sed 's/}//g' | sed 's/ //g')
  local group_name=$(echo "$group_details" | awk -F "," '{for(i=1; i<=NF; i++) if($i ~/name/) print substr($i,index($i,":")+1)}' | sed 's/$}//g' | sed 's/ //g')
  
  if (( $running_cnt < $min_running_cnt )); then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "running count $running_cnt, less than $min_running_cnt in group $group_name" >> $first_log
  fi
  
  echo 0
}

function start_nifi() {
  $($nifi_home/bin/nifi.sh start > /dev/null 2>&1)
}

function stop_nifi() {
  $($nifi_home/bin/nifi.sh stop > /dev/null 2>&1)
}

# check the Nifi process, if none, try to start Nifi
function process_check() {
  local nifi_process=$(ps -ef|grep -i nifi-properties|grep -v grep)
  if [[ "$nifi_process" == "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "nifi is stopped, gonna start it" >> $first_log
    $(start_nifi)
    #echo "Nifi_Alert|$(date +%Y-%m-%d" "%k:%M:%S)|Nifi not started, starting it"
    echo -1
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "nifi is running" >> $first_log
    local pid=$(get_pid "nifi-properties")
    local proc_cpu=$(get_proc_cpu $pid)
    
    if (( $proc_cpu > $max_cpu )); then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "nifi CPU usage: $proc_cpu, gonna restart it" >> $first_log
      $(stop_nifi)
      sleep 1m
      $(start_nifi)
      echo -1
      return 0
    fi
    echo 0
  fi
}

function main() {
  $(init)
  
  local pre_check_result=$(pre_check)
  if (( $pre_check_result != 0 )); then
    return 0
  fi
  
  local process_check_result=$(process_check)
  if (( $process_check_result != 0 )); then
    return 0
  fi
  
  # generate the pem for Nifi Restful API invoke usage via SSL
  $(p12_2_pem)
  if [[ "$(is_file $nifi_cert_pem)" != "0" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "cert pem file: $nifi_cert_pem not exist" >> $first_log
    #echo "Nifi_Alert|$(date +%Y-%m-%d" "%k:%M:%S)|Nifi .pem cert not exist"
    return 0
  fi
  
  # check the root group for the running count
  local group_details=$(pg_details_check $root_group_id)
  if [[ "$group_details" != "0" ]]; then
    return 0
  fi  
  
  # check everything in the root group recursively
  $(group_check $root_group_id)
}

$(main)

# echo to tivoli agent 88
#result=$(main)

#if [[ "$result" != "" ]]; then
#  echo $result
#fi