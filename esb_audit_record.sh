#!/bin/bash
# used to collect data from AuditRecord.*.log and format it to json
#   get the data using 10 minutes as a basic time unit and record the timestamp seconds
#   user should not be too many in 10 minutes so the json data wouldn't be too big
#   >= time_start && < last_time(record last_time into $read_record)
#   { "audit_records": {"data": [{"time_start": "", "last_time":"", "user": {"successful_user": {"username":"", "times":""}, "failed_user": {"username":"", "times":""}}, "app": {"successful_app": {"app_name":"", "times":""}, "failed_app": {"app_name":"", "times":""}}}, {}, {} ], "env": ""}}
# ./mongo ns_esb --eval 'db.audit_record.insert({key:"hello"})'
# ./mongo 9.110.168.121/ns_esb --eval 'db.customer.insert({"firstName":"Arya","secondName":"Stark"})'
# while true; sec=$(cat read_record.txt|awk -F "=" '{print $2}'); do time ./esb_audit_record.sh; s=$(cat read_record.txt|awk -F "=" '{print $2}'); date -d@$s; if(( $sec==$s )); then break; fi; sleep 3; done
# Author: Joey Deng(dengtin@hotmail.com)
readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"

# format: time_gap=<10> \n time_total=<60> ...
#   (which means 6 records which contains formated data of 10 minutes for each)
readonly app_cfg="$base_dir/$base_name.cfg"
# the file is used to record the file read last time and the value collected
#   format: last_time=<seconds>
#   should >= last_time at the next time
readonly read_record="$base_dir/read_record.txt"

readonly log_dir="$base_dir/logs"
readonly log_name="$log_dir/$base_name.log"
readonly first_log="$log_name"".0"

# 5M * 2
readonly log_limit="10485760"
readonly log_size="5"
readonly log_info=" Info "
readonly log_error=" Error "
readonly log_warn=" Warning "
readonly log_debug=" Debug "

# get global constants from $app_cfg
readonly app_env=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^app_env/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly time_gap=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^time_gap/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly time_total=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^time_total/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly is_debug=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^is_debug/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly source_dir=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^source_dir/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly archive_dir=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^archive_dir/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly mongodb_bin=$(cat $app_cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^mongodb_bin/) print $2}' | sed -e 's/[ \t\/]*$//')
readonly run_times=$(($time_total/$time_gap))
#readonly ignored_users=("server:")
readonly ignored_users=()
#readonly ignored_apps=("Service_Integration_Bus")
readonly ignored_apps=()
readonly mongodb_db="ns_esb"
readonly mongodb_collection="audit_record"

# get last timestamp seconds from $read_record
# readonly last_time=$(cat $read_record | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^last_time/) print $2}' | sed -e 's/[ \t\/]*$//')

# param1: dir name
function is_dir() {
  if [ -d "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

# param1: dir name
function is_dir_null() {
  local f=$(find "$1" -mindepth 1 -print -quit 2>/dev/null)
  if [[ "$f" == ""  ]]; then
    echo 0
  else
    echo -1
  fi
}

# param1: file name
function is_file() {
  if [ -f "$1" ]; then
    echo 0
  else
    echo -1
  fi
}

# param1: dir name
# param2: permission number
function make_dir() {
  if [ ! -d "$1" ]; then
    mkdir -pm "$2" "$1" 2>/dev/null
  fi
}

# param1: file name
# param2: permission number
function make_file() {
  if [ ! -f "$1" ]; then
    touch "$1" 2>/dev/null
    chmod "$2" "$1" 2>/dev/null
  fi
}

# get file size in "block" unit
# param1:file name with absolute path
# return:file size in "block" unit
function get_filesize() {
  local size=$(stat -c %s "$1")
  echo "$size"
}

# param1: file name
# return: file last modification time in seconds format
function get_file_seconds() {
  local seconds=$(stat -c %Y $1)
  echo $seconds
}

# param1: source string
# param2: pattern
function is_match() {
  local re="$2"
  if ! [[ $1 =~ $re ]] ; then
    echo -1
  else
    echo 0
  fi
}

# param1: source string
function is_num() {
  local pattern='^-?[0-9]+([.][0-9]+)?$'
  local match=$(is_match "$1" "$pattern")
  echo $match
}

# param1: source string
function is_positive_int() {
  local pattern='^[0-9]+$'
  local match=$(is_match "$1" "$pattern")
  echo $match
}

# if an array contains a element
# usage: $(is_in_arr "str" "${array[@]}")
function is_in_arr() {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && echo 0 && return 0; done
  echo -1
}

# if an array contains a element
# usage: $(is_map_arr "str" "${array[@]}")
function is_map_arr() {
  local e match="$1"
  shift
  for e; do [[ "$match" == *"$e"* ]] && echo 0 && return 0; done
  echo -1
}

# param1: seconds
# e.g. 1527563745 -> "Tue May 29 05:15:45 CEST 2018" -> "Tue May 29 00:00:00 CEST 2018" -> seconds
function get_day_start(){
  local date_str=$(date -d @"$1")
  date_str=$(echo $date_str | awk '{gsub("[0-9]+:[0-9]+:[0-9]+", "00:00:00", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
}


# param1: seconds
# e.g. 1527563745 -> "Tue May 29 05:15:45 CEST 2018" -> "Tue May 29 23:59:59 CEST 2018" -> seconds
function get_day_end(){
  local date_str=$(date -d @"$1")
  date_str=$(echo $date_str | awk '{gsub("[0-9]+:[0-9]+:[0-9]+", "23:59:59", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
}

# param1: seconds
# e.g. 1527563745 -> "Tue May 29 05:15:45 CEST 2018" -> "Tue May 29 05:00:00 CEST 2018" -> seconds
function get_hour_start(){
  local date_str=$(date -d @"$1")
  local hour=$(date -d@"$1" +%H)
  date_str=$(echo $date_str | awk -v var="$hour" '{gsub("[0-9]+:[0-9]+:[0-9]+", var":00:00", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
}

# param1: seconds
# e.g. 1527563745 -> "Tue May 29 05:15:45 CEST 2018" -> "Tue May 29 05:59:59 CEST 2018" -> seconds
function get_hour_end(){
  local date_str=$(date -d @"$1")
  local hour=$(date -d@"$1" +%H)
  date_str=$(echo $date_str | awk -v var="$hour" '{gsub("[0-9]+:[0-9]+:[0-9]+", var":59:59", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
}

# param1: seconds
# param2: gap minutes, can be divided by 60, like 2, 3 ,5, 10, 20...
# e.g. gap=5, 03 -> 00, 05 -> 05, 06 -> 05, 11 -> 10
function get_gap_start() {
  local date_str=$(date -d @"$1")
  local minutes=$(date -d@"$1" +%M)
  local round_down_minutes=$((minutes / $2))
  minutes=$((round_down_minutes * $2))
  date_str=$(echo $date_str | awk -v var="$minutes" '{gsub(":[0-9]+:[0-9]+", ":"var":00", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
}

# param1: seconds
# param2: gap minutes, can be divided by 60, like 2, 3 ,5, 10, 20...
# e.g. gap=5, 03 -> 05, 05 -> 05, 06 -> 10, 11 -> 15
# to be done, need to consider hour and day change
function get_gap_end() {
  local date_str=$(date -d @"$1")
  local minutes=$(date -d@"$1" +%M)
  local round_up_minutes=$(( (minutes+$2-1) / $2))
  minutes=$((round_up_minutes * $2))
  date_str=$(echo $date_str | awk -v var="$minutes" '{gsub(":[0-9]+:[0-9]+", ":"var":00", $0); print $0}')
  local seconds=$(date -d "$date_str" +%s)
  echo $seconds
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

# param1: mongodb bin path
# param2: db name
# param3: db collection
# param4: document(json string)
# e.g. $(mongodb_insert "/opt/IBM/mongodb/bin" "ns_esb" "audit_record" "{key:\"joey\"}")
function mongodb_insert(){
  local result=$("$1"/mongo "$2" --eval 'db.'"$3"'.insert('"$4"')')
  if [[ "$result" == "" || "$result" == *"Error"* || "$result" == *"Failed"* ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "inserted into mongodb failed: $result" >> $first_log
    echo -1
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "inserted into mongodb successful: $result" >> $first_log
    echo 0
  fi
}

# preparation work
function init(){
  $(make_dir "$log_dir" "777")
  $(make_dir "$archive_dir" "777")
  $(make_file "$first_log" "666")
  $(make_file "$read_record" "666")
  $(make_file "$app_cfg" "644")
  
  local size=$(get_filesize "$first_log")
  if [[ "$size" -gt "$log_limit" ]]; then
    $(roll_log)
  fi

  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "initialized" >> $first_log
}

# param1: source environment string
function vaildate_env() {
  local pattern="^(bijs|nedt|dpk|reis|ovcp)_(p|a|t|d)_dc[0-9]+_[A-Za-z0-9]+$"
  local match=$(is_match "$1" "$pattern")
  echo $match
}

# param1: file name
function is_archive() {
  local pattern="BinaryAudit_.*_[0-9]+\.[0-9]+\.[0-9]+_[0-9]+\.[0-9]+\.[0-9]+\.log$"
  local match=$(is_match "$1" "$pattern")
  echo $match
}

# check if the .cfg file is configured correctly
# return: 0 if normal, -1 if error
function pre_check() {
  local items=("app_env" "time_gap" "time_total" "is_debug" "source_dir" "archive_dir" "mongodb_bin")
  local values=($app_env $time_gap $time_total $is_debug $source_dir $archive_dir $mongodb_bin)
  local i=0
  local has_error=false
  
  for item in ${items[*]}; do
    i=$((i+1))
    if [[ "${values[i-1]}" == "" ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "$item not set" >> $first_log
      has_error=true
      continue
    fi
    
    if [[ "$item" == "time_gap" || "$item" == "time_total" ]]; then
      local result=$(is_num "${values[i-1]}")
      if (( $result != 0 )); then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "${values[i-1]} not a positive integer" >> $first_log
        has_error=true
        continue
      fi
    fi
    
    if [[ "$item" == "app_env" ]]; then
      local result=$(vaildate_env "$app_env")
      if (( $result != 0 )); then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "app_env: $app_env invalid" >> $first_log
        has_error=true
        continue
      fi
    fi

    if [[ "$item" == "source_dir" || "$item" == "archive_dir" || "$item" == "mongodb_bin" ]]; then
      if [[ "$(is_dir ${values[i-1]})" != "0" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "directory ${values[i-1]} not exist" >> $first_log
        has_error=true
        continue
      fi
    fi        
  done
  
  if [[ $has_error == true ]]; then
    echo -1
    return 0
  fi
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "configured correctly" >> $first_log
  echo 0
}

# param1: time seconds
function write_record() {
  echo -e "last_time=$1" > $read_record
}

# the 1st timestamp seconds in a log
# param1: file name
function get_start_seconds() {
  local timestamp=$(cat $1 | awk -F "|" '{if($1 ~/^Seq/) {for(i=1;i<NF;i++) {if($i ~/CreationTime/) {print substr($i,index($i,"=")+1); exit}}}}' | sed 's/^ //g')
  local seconds=$(date -d "$timestamp" +%s) 
  
  echo $seconds
}

# the end timestamp seconds in a log
# param1: file name
function get_end_seconds() {
  local timestamp=$(cat $1 | tail -1 | awk -F "|" '{if($1 ~/^Seq/) {for(i=1;i<NF;i++) {if($i ~/CreationTime/) {print substr($i,index($i,"=")+1); exit}}}}' | sed 's/^ //g')
  local seconds=$(date -d "$timestamp" +%s) 
  
  echo $seconds
}

# param1: dir name
# param2: start seconds
# param3: end seconds
# return files array in the time range
function ls_files() {
  local files=()
  local result=()
  files=$(ls -t -d -1 $1/*.* | awk '{if($NF ~/Audit.*log/) print $0}')
  
  local i=0
  for f in ${files[*]}; do
    local log_end=$(get_end_seconds "$f")
    local log_start=$(get_start_seconds "$f")
    
    if (( $2 - $log_end > 0 || $3 - $log_start <= 0 )); then
      continue
    fi
    
    result[i]=$f
    i=$(($i+1))
  done
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "files to be handled: $result" >> $first_log
  fi    
  
  echo $result
}

# param1: dir
# param2: seconds
# get the start_seconds which min(start_seconds >= seconds)
function get_latest_start() {
  local files=()
  local log_start=-1
  files=$(ls -rt -d -1 $1/*.* | awk '{if($NF ~/Audit.*log/) print $0}')

  for f in ${files[*]}; do
    log_start=$(get_start_seconds "$f")
    if (( $log_start - $2 >= 0  )); then
      break
    else
      log_start=-1    
    fi
  done
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "latest start: $log_start" >> $first_log
  fi  

  echo $log_start
}

# param1: file
# param2: seconds
# get the line number which max(CreationTime < $2)
function get_line_nr() {
  local start_line=1
  local end_line=$(cat $1 | wc -l)
  local line_nr=1

  while (( $start_line <= $end_line )); do
    local mid_line=$(( (start_line+end_line)/2 ))
    local timestamp=$(cat $1 | awk NR==$mid_line | awk -F '|' '{if($1 ~/^Seq/) {for(i=1;i<NF;i++) {if($i ~/CreationTime/) {print substr($i,index($i,"=")+1); exit}}}}' | sed 's/^ //g')
    local seconds=$(date -d "$timestamp" +%s)
    
    if (( $2 > $seconds  )); then
      line_nr=$mid_line
      start_line=$((mid_line+1))
    elif (( $2 <= $seconds )); then
      end_line=$((mid_line-1))
    fi
  done
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "line_nr: $line_nr" >> $first_log
  fi    

  echo $line_nr
}


# get last checked seconds from record file
function get_last_record() {
  local last_time=-1
  if (( $(is_file $read_record) == 0 )); then
    last_time=$(cat $read_record | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^last_time/) print $2}' | sed -e 's/[ \t\/]*$//')
    if (( $(is_positive_int $last_time) != 0 )); then
      last_time=-1
    fi
  fi
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "last record checked: $last_time" >> $first_log
  fi
  
  echo $last_time
}

# param1: dir
function get_min_seconds() {
  local min=-1
  local files=$(ls -t -d -1 $1/*.* | awk '{if($NF ~/Audit.*log/) print $0}')

  local i=0
  for f in ${files[*]}; do
    if (( $i == 0 )); then
      min=$(get_start_seconds "$f")
      continue
    fi
    
    local seconds=$(get_start_seconds "$f")
    if (( $seconds < $min  )); then
      min=$seconds
    fi
    
    i=$(($i+1))
  done
  echo $min
}

# param1: dir
function get_max_seconds() {
  local max=-1
  local files=$(ls -t -d -1 $1/*.* | awk '{if($NF ~/Audit.*log/) print $0}')

  local i=0
  for f in ${files[*]}; do
    if (( $i == 0 )); then
      max=$(get_end_seconds "$f")
      continue
    fi
    
    local seconds=$(get_end_seconds "$f")
    if (( $seconds > $max  )); then
      max=$seconds
    fi
    
    i=$(($i+1))
  done
  echo $max
}

# param1: source dir
# param2: archive dir
# move file in $source_dir to $archive_dir and delete files older than 30 days
function archive_files() {
  local files=$(ls -t -d -1 $1/*.* | awk '{if($NF ~/Audit.*log/) print $0}')
  local last_record=$(get_last_record)
  
  for f in ${files[*]}; do
    local end_seconds=$(get_end_seconds "$f")
    local should_be_archived=$(is_archive "$f")
    if (( $end_seconds - $last_record < 0 &&  $should_be_archived == 0)); then
      mv $f $2
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "file archived: $f" >> $first_log
    fi
  done
  
  find $2 -maxdepth 1 -mtime +30 -type f -name "BinaryAudit*" -delete
}

# param1: seconds
function earlier_than_now() {
  local now_seconds=$(date +%s)
  if (( $now_seconds - $1 > 0 )); then
    echo 0
  else
    echo -1
  fi
}

# param1: dir
# param2: start seconds
# param3: end seconds
# return a new read record if no record file in scan range
function set_read_record() {
  local new_end_seconds=-1
  local result=$(earlier_than_now $3)
  
  if (( $result == 0 )); then
    local latest_start=$(get_latest_start $1 $3)
    if (( $latest_start != -1 )); then
      new_end_seconds=$latest_start
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "set read record to latest start seconds" >> $first_log
    else
      new_end_seconds=$2        
    fi
  else
    new_end_seconds=$2
  fi
  
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "no record in time range $2-$3, set read record to $new_end_seconds" >> $first_log

  echo $new_end_seconds
}

# param1: file name
# param2: start seconds
# param3: end seconds
# param4: line number
# return: key=xx,times=xx;...
function get_succ_user() {  
  local result=$(cat "$1" | tail -n +$4 | awk -v start="$2" -v end="$3" -F "|" '{if($1 ~/^Seq/) {timestr=substr($22,index($22,"=")+2); "date -d \""timestr"\" +%s"|getline seconds; key=substr($12,index($12,"=")+2); gsub(/^[ \t]+|[ \t]+$/, "", key); if($3 ~/SUCCESSFUL/ && seconds-start>=0 && seconds-end<0) {cnt[key]++;}; if(seconds-end>=0){exit} }} END {for(var in cnt) { str=str"key="var",times="cnt[var]";"};  gsub(/^[;]+|[;]+$/, "", str); print str}')
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "succeded user: $result" >> $first_log
  fi
  
  echo $result
}

# param1: file name
# param2: start seconds
# param3: end seconds
# param4: line number
# return: key=xx,times=xx;...
function get_failed_user() {
  local result=$(cat "$1" | tail -n +$4 | awk -v start="$2" -v end="$3" -F "|" '{if($1 ~/^Seq/) {timestr=substr($22,index($22,"=")+2); "date -d \""timestr"\" +%s"|getline seconds; key=substr($12,index($12,"=")+2); gsub(/^[ \t]+|[ \t]+$/, "", key); if($3 !~/SUCCESSFUL/ && seconds-start>=0 && seconds-end<0) {cnt[key]++;}; if(seconds-end>=0){exit} }} END {for(var in cnt) { str=str"key="var",times="cnt[var]";"};  gsub(/^[;]+|[;]+$/, "", str); print str}')
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "failed user: $result" >> $first_log
  fi
  
  echo $result
}

# param1: file name
# param2: start seconds
# param3: end seconds
# param4: line number
# return: key=xx,times=xx;...
function get_succ_app() {
  local result=$(cat "$1" | tail -n +$4 | awk -v start="$2" -v end="$3" -F "|" '{if($1 ~/^Seq/) {timestr=substr($22,index($22,"=")+2); "date -d \""timestr"\" +%s"|getline seconds; key=substr($10,index($10,"=")+2); gsub(/^[ \t]+|[ \t]+$/, "", key); if($3 ~/SUCCESSFUL/ && seconds-start>=0 && seconds-end<0) {cnt[key]++;}; if(seconds-end>=0){exit} }} END {for(var in cnt) { str=str"key="var",times="cnt[var]";"};  gsub(/^[;]+|[;]+$/, "", str); print str}')
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "succeded app: $result" >> $first_log
  fi
  
  echo $result
}

# param1: file name
# param2: start seconds
# param3: end seconds
# param4: line number
# return: key=xx,times=xx;...
function get_failed_app() {
  local result=$(cat "$1" | tail -n +$4 | awk -v start="$2" -v end="$3" -F "|" '{if($1 ~/^Seq/) {timestr=substr($22,index($22,"=")+2); "date -d \""timestr"\" +%s"|getline seconds; key=substr($10,index($10,"=")+2); gsub(/^[ \t]+|[ \t]+$/, "", key); if($3 !~/SUCCESSFUL/ && seconds-start>=0 && seconds-end<0) {cnt[key]++;}; if(seconds-end>=0){exit} }} END {for(var in cnt) { str=str"key="var",times="cnt[var]";"};  gsub(/^[;]+|[;]+$/, "", str); print str}')
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "failed app: $result" >> $first_log
  fi
  
  echo $result
}

# param1: file name
# param2: start seconds
# param3: end seconds
# param4: line number
# param5: data type in ("succ_user", "failed_user", "succ_app", "failed_app")
# return: key=xx,times=xx;...
function get_data() {  
  local result="";
  if [[ "$5" == "succ_user" ]]; then
    result=$(get_succ_user "$1" "$2" "$3" "$4")
  elif [[ "$5" == "failed_user" ]]; then
    result=$(get_failed_user "$1" "$2" "$3" "$4")
  elif [[ "$5" == "succ_app" ]]; then
    result=$(get_succ_app "$1" "$2" "$3" "$4")
  elif [[ "$5" == "failed_app" ]]; then
    result=$(get_failed_app "$1" "$2" "$3" "$4")
  fi
  
  result=$(echo $result | sed -e 's/[ \t\/]*$//' | sed -e 's/[ \t]/_/g')
  
  if [[ "$is_debug" == "true" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "$5 data: $result" >> $first_log
  fi  
  
  echo $result
}

function main() {
  $(init)
  local pre_check_result=$(pre_check)
  if (( $pre_check_result != 0 )); then
    return 0
  fi
  
  local start_seconds=$(get_last_record)
  if (( $start_seconds == -1 )); then
    start_seconds=$(get_min_seconds $source_dir)
    if (( $start_seconds == -1 )); then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "no audit record data, will exit" >> $first_log
      return 0
    fi
  fi
  
  local json_start_seconds=$(get_gap_start $start_seconds $time_gap)
  local end_seconds=$(($json_start_seconds+time_gap*60))
  local json_end_seconds=$end_seconds
  local has_data=-1
  local data_types=("succ_user" "failed_user" "succ_app" "failed_app")
  local json_str="{\"audit_records\":{\"env\":\"$app_env\",\"time_start\":\"$json_start_seconds\",\"data\":["
  
  declare -A succ_user_map
  declare -A failed_user_map
  declare -A succ_app_map
  declare -A failed_app_map
  
  for (( i=0; i < $run_times; ++i )); do
    #local json_data="{\"start_seconds\":\"$start_seconds\",\"end_seconds\":\"$end_seconds\""
    local json_data="{\"start_seconds\":\"$json_start_seconds\",\"end_seconds\":\"$json_end_seconds\""
    local json_user="\"user\":{"
    local json_app="\"app\":{"
    local has_this_data=-1
    
    if [[ "$is_debug" == "true" ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "range: [$start_seconds,$end_seconds)" >> $first_log
    fi  
  
    local files=$(ls_files "$source_dir" $start_seconds $end_seconds)
    
    if [[ $files == "" ]]; then
      end_seconds=$(set_read_record $source_dir $start_seconds $end_seconds)
      if [[ "$is_debug" == "true" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "no files in time range, stop scanning" >> $first_log
      fi       
      break
    fi    

    local renew_end_seconds=-1    
    for f in ${files[*]}; do
      local file_end_time=$(get_end_seconds "$f")
      # scan from $line_nr line, faster
      local line_nr=$(get_line_nr "$f" $start_seconds)
      local data=""
      local is_earlier=$(earlier_than_now $file_end_time)
      local capture_data=-1
      renew_end_seconds=-1
      
      # only capture data if the file end seconds is later than the end seconds of this loop
      #   or the file end seconds is earlier than now seconds which means there would be
      #   no data in the file end seconds anymore      
      if (( $file_end_time - $end_seconds < 0 )); then
        if (( $is_earlier == 0 )); then
          # capture the data from start to the file end
          capture_data=0
          # set the next start to file end seconds + 1
          renew_end_seconds=0
        else
          # stop scaning, set the next start to this start
          renew_end_seconds=1
        fi
      else
        # capture data from start to end
        capture_data=1
      fi
      
      local type
      for type in ${data_types[*]}; do
        if (( $capture_data == 0 )); then
          data=$(get_data "$f" "$start_seconds" "$(($file_end_time+1))" "$line_nr" "$type")
        elif (( $capture_data == 1 )); then
          data=$(get_data "$f" "$start_seconds" "$end_seconds" "$line_nr" "$type")
        else
          break
        fi
        
        if [[ "$data" != "" ]]; then
          has_data=0
          has_this_data=0
          local arr=$(echo "$data" | awk -F ";" 'BEGIN {ORS=" "} {for(i=1;i<=NF;i++) print $i}')
          local key=""
          local value=0
          
          local var
          for var in ${arr[*]}; do
            key=$(echo $var | awk -F "," '{print substr($1,index($1,"=")+1)}')
            value=$(echo $var | awk -F "," '{print substr($2,index($2,"=")+1)}')
            if [[ "$type" == "succ_user" ]]; then
              if (( $(is_map_arr "$key" "${ignored_users[@]}") == 0 )); then
                continue
              fi
              succ_user_map[$key]=$((succ_user_map[$key]+$value))
            elif [[ "$type" == "failed_user" ]]; then
              if (( $(is_map_arr "$key" "${ignored_users[@]}") == 0 )); then
                continue
              fi            
              failed_user_map[$key]=$((failed_user_map[$key]+$value))
            elif [[ "$type" == "succ_app" ]]; then
              if (( $(is_map_arr "$key" "${ignored_apps[@]}") == 0 )); then
                continue
              fi            
              succ_app_map[$key]=$((succ_app_map[$key]+$value))
            elif [[ "$type" == "failed_app" ]]; then
              if (( $(is_map_arr "$key" "${ignored_apps[@]}") == 0 )); then
                continue
              fi            
              failed_app_map[$key]=$((failed_app_map[$key]+$value))
            fi
          done               
        fi
      done
      
      if (( $renew_end_seconds == 0 )); then
        end_seconds=$(($file_end_time+1))
        break
      elif (( $renew_end_seconds == 1 )); then
        end_seconds=$start_seconds
        break
      fi      
    done
    
    local json_succ_user=""
    local json_failed_user=""
    local json_failed_app=""
    local json_succ_app=""
    
    for key in "${!succ_user_map[@]}"; do
      json_succ_user=$json_succ_user"{\"username\":\"$key\",\"times\":\"${succ_user_map[$key]}\"},"
    done
    
    for key in "${!failed_user_map[@]}"; do
      json_failed_user=$json_failed_user"{\"username\":\"$key\",\"times\":\"${failed_user_map[$key]}\"},"
    done

    for key in "${!succ_app_map[@]}"; do
      json_succ_app=$json_succ_app"{\"app\":\"$key\",\"times\":\"${succ_app_map[$key]}\"},"
    done

    for key in "${!failed_app_map[@]}"; do
      json_failed_app=$json_failed_app"{\"app\":\"$key\",\"times\":\"${failed_app_map[$key]}\"},"
    done
    
    json_succ_user=$(echo $json_succ_user | sed 's/,$//g')
    json_failed_user=$(echo $json_failed_user | sed 's/,$//g')
    json_user=$json_user"\"successful_user\":[$json_succ_user],\"failed_user\":[$json_failed_user]}"
    
    json_succ_app=$(echo $json_succ_app | sed 's/,$//g')
    json_failed_app=$(echo $json_failed_app | sed 's/,$//g')
    json_app=$json_app"\"successful_app\":[$json_succ_app],\"failed_app\":[$json_failed_app]}"
    
    if (( $has_this_data == 0 )); then
      json_str=$json_str$json_data","$json_user","$json_app"},"
    fi  
    
    # reset the associative array for the next loop
    succ_user_map=()
    failed_user_map=()
    succ_app_map=()
    failed_app_map=()
    
    if (( $renew_end_seconds != -1 )); then
      if [[ "$is_debug" == "true" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_debug ${FUNCNAME[0]} "file end seconds < scan end, skip the rest file" >> $first_log
      fi     
      break
    fi
    
    if (( $i < $run_times-1 )); then
      start_seconds=$end_seconds
      end_seconds=$(($start_seconds+$time_gap*60))
      json_start_seconds=$start_seconds
      json_end_seconds=$end_seconds
    fi
  done
  
  json_str=$(echo $json_str | sed 's/,$//g')
  #json_str=$json_str"],\"time_end\":\"$end_seconds\"}}"
  json_str=$json_str"],\"time_end\":\"$json_end_seconds\"}}"
  if (( $has_data == -1 )); then
    json_str=""
  else
    local is_inserted=$(mongodb_insert "$mongodb_bin" "$mongodb_db" "$mongodb_collection" "$json_str")
    if (( $is_inserted == -1 )); then
      return 0
    fi    
  fi
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "json_str:$json_str" >> $first_log
  $(write_record $end_seconds)
  $(archive_files $source_dir $archive_dir)

  echo $json_str
}

# echo to tivoli agent
result=$(main)
echo $result