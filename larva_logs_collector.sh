#!/bin/bash
# Used to compress logs and upload to Tivoli server
#   by calling RESTful webservice

# curl -sX POST -F 'file=@/home/dengtian/Code/JoeyCode/py/processMonitor.py' -F 'fileName=processMonitor' http://localhost:8080/upload
# curl -sX GET http://9.112.132.90:8888/logs/WESB-P-ES002/*
# cd ~/Code/JoeyCode/sh/test && tar -zcvf /home/dengtian/larva_logs/test.tgz test.log.*
# ls -At ./|awk '{"stat -c %Y \""$1"\""|getline sec; print $1,sec}'
# System*, *\.log\.*
# cat SystemOut_127.log |grep -n "^\[" |awk -v start=1487873108 -v end=1487873233 '{datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; line=substr($1,1,index($1,":")-1); if(!i && seconds>=start) {print line; i++} ; if(!j && seconds>end) {print line; j++}} END{if(!j) print line}'

readonly script_path=$(readlink -f $0)
readonly base_dir=$(dirname $script_path)
# get file name without extension
base_name="${script_path##*/}"
readonly base_name="${base_name%.*}"
readonly cfg="$base_dir/$base_name.cfg"
readonly log_dir="$base_dir/logs"
readonly log_name="$log_dir/$base_name.log"
readonly first_log="$log_name"".0"
# 5M
readonly log_limit="5242880"
readonly log_size="4"
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

# get file modification time in seconds format
# param1: file name with absolute path
# return: file modification time in seconds format
function get_file_seconds() {
  local seconds=$(stat -c %Y $1)
  echo $seconds
}

# get file size in "block" unit
# param1: file name with absolute path
# return: file size in "block" unit
function get_filesize() {
  local size=$(stat -c %s "$1")
  echo "$size"
}

# binary search in log file via the timestamp
# param1: file name with absolute path
# param2: the total line count of the file
# param3: the time in seconds to be seached
# return: the line number which best matchs the specified time 
function bin_search() {
  local log_file=$1
  local last=$2
  local value=$3

  local begin=1
  local mid=-1
  local line_str=""
  local line_nr=-1
  local line_time=-1

  while (( begin <= last )); do
    mid=$(( (begin+last)/2 ))
    #line_str=$(cat $log_file |grep -n "^\[" |sed -n "$mid"p)
    line_str=$(cat $log_file |sed -n "$mid"p)
    line_nr=$(echo $line_str| awk '{print substr($1, 1, index($1,":")-1)}')
    line_time=$(echo $line_str| awk '{datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; print seconds}')

    if (( $line_time > $value )); then
      last=$(( mid-1 ))
    elif (( $line_time < $value )); then
      begin=$(( mid+1 ))
    else
      break
    fi
  done

  echo $line_nr
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

# remove files beyond specfied days in a specified dir
# param1: a number with unit "day"
# param2: the dir
function rm_overdue_files() {
  local upload_failpath=$1
  local upload_overdue=$2
  local due_seconds=$(date -d"$upload_overdue days ago" +%s)
  
  if [[ "upload_failpath" == "" || "$upload_overdue" == "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "parameter illegal" >> $first_log
    return 0
  fi
  
  local files=$(ls $upload_failpath)
  files=( $files )
  for f in ${files[*]}; do
    file_seconds=$(get_file_seconds $upload_failpath"/"$f)
    if [[ "$due_seconds" -gt "$file_seconds" ]]; then
      rm -rf $upload_failpath"/"$f
    fi
  done
}

# test if the webservice was available
# param1: url string
# return: 0 if success, -1 if failed
function test_connectivity() {
  local code=$(curl -sL -w "%{http_code}" "$1" -o /dev/null)
  if [ "$code" -eq "000" ]; then
    echo -1
  else
    echo 0
  fi
}

# get json string from webservice
# return: json array string like [{"start":213123131231, "end":23222333332121, "domain":"BIJS"},{***},...]
function get_json() {
  local alert_endpoint=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^alert_endpoint/) print $2}' | sed -e 's/[ \t\/]*$//')
  if [ "$(test_connectivity $alert_endpoint)" -ne "0" ]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "$alert_endpoint not available" >> $first_log
    echo ""
    return 0
  fi

  local json_str=$(curl -sX GET $alert_endpoint)
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "json array: $json_str" >> $first_log
  echo $json_str
}

# get logs based on given path and start seconds which the file modification time should be bigger than it
# param1: log file with absolute path
# param2: start seconds
# return logs array which need to be collected
function get_logs() {
  local upper_path=$(echo $1| awk '{print toupper($0)}')
  local start=$2

  local logs=()
  if [[ "$upper_path" == *"APPTARGET"* || "$upper_path" == *"MESSAGING"* || "$upper_path" == *"DMGR"* ]]; then
    logs=$(ls -Atd1 $1/System*| awk -v mystart="$start" 'BEGIN {ORS = " "} {"stat -c %Y \""$1"\""|getline sec; if(sec>=mystart) print $1}')
  elif [[ "$upper_path" == *"FFDC"* ]]; then
    logs=$(ls -Atd1 $1/*| awk -v mystart="$start" 'BEGIN {ORS = " "} {"stat -c %Y \""$1"\""|getline sec; if(sec>=mystart) print $1}')
  elif [[ "$upper_path" == *"APPLOGS"* ]]; then
    logs=$(ls -Atd1 $1/*\.log\.*| awk -v mystart="$start" 'BEGIN {ORS = " "} {"stat -c %Y \""$1"\""|getline sec; if(sec>=mystart) print $1}')
  elif [[ "$upper_path" == *"QMGR"* ]]; then
    logs=$(ls -Atd1 $1/AMQ*\.LOG| awk -v mystart="$start" 'BEGIN {ORS = " "} {"stat -c %Y \""$1"\""|getline sec; if(sec>=mystart) print $1}')
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "$1 log file not acceptable" >> $first_log
  fi

  echo $logs
}

# get line number based on given time seconds in the log line by line
# param1: log name with absolute path
# param2: start seconds
# param3: end seconds
# return: array contains start and end line, eg. (2 5)
function get_line_nr() {
  local log=$1
  local start=$2
  local end=$3
  local line_nr=""

  # if the time seconds in the 1st line of the log is bigger than the end seconds, then it's obviously our of range
  local in_range=$(cat $log |grep -n "^\[" |head -1 |awk -v myend=$end '{datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; line=substr($1,1,index($1,":")-1); if (seconds >= 0 && seconds <= myend) print 0}' | sed '/^\s*$/d')

  # if in range, get a line number str which contains start and end line number
  if [[ "$in_range" == "0" ]]; then
    line_nr=$(cat $log |grep -n "^\[" |awk -v mystart=$start -v myend=$end 'BEGIN {ORS = " "} {datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; line=substr($1,1,index($1,":")-1); if(!i && seconds>=mystart) {print line; i++} ; if(!j && seconds>myend) {print line; j++}} END{if(!j) print line}' | sed '/^\s*$/d')
  fi

  if [[ "$line_nr" != "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "gonna save lines in range $line_nr in log $log" >> $first_log
  fi
  
  echo $line_nr
}

# get line number based on given time seconds in the log using binary search
# param1: log name with absolute path
# param2: start seconds
# param3: end seconds
# return: array contains start and end line, eg. (2 5)
function get_line_nr_bin() {
  local log=$1
  local start=$2
  local end=$3
  local start_line=-1
  local end_line=-1
  local line_nr=""

  if [[ "$log" != *".tmp"* ]]; then
    local tmp_log=$log".tmp"
    $(cat $log |grep -n "^\[" > $tmp_log)
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "not gonna scan log name end with .tmp" >> $first_log
    echo ""
    return 0
  fi

  # if the time seconds in the 1st line of the log is bigger than the end seconds, then it's obviously our of range
  #local in_range=$(cat $log |grep -n "^\[" |head -1 |awk -v myend=$end '{datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; line=substr($1,1,index($1,":")-1); if (seconds >= 0 && seconds <= myend) print 0}' | sed '/^\s*$/d')
  local in_range=$(cat $tmp_log |head -1 |awk -v myend=$end '{datestr=substr($1,index($1,"[")+1)" "substr($2,1,length($2)-4); gsub("-","/",datestr); "date -d \""datestr"\" +%s"|getline seconds; line=substr($1,1,index($1,":")-1); if (seconds >= 0 && seconds <= myend) print 0}' | sed '/^\s*$/d')

  # if in range, get a line number str which contains start and end line number
  if [[ "$in_range" == "0" ]]; then
    #local line_cnt=$(cat $log |grep "^\[" |wc -l)
    #start_line=$(bin_search "$log" $line_cnt $start)
    #end_line=$(bin_search "$log" $line_cnt $end)
    local line_cnt=$(cat $tmp_log |wc -l)
    start_line=$(bin_search "$tmp_log" $line_cnt $start)
    end_line=$(bin_search "$tmp_log" $line_cnt $end)
  fi
  $(rm -rf $tmp_log)

  if [[ "$start_line" != "-1" && "$end_line" != "-1" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "gonna save lines from line $start_line to $end_line in log $log" >> $first_log
    line_nr=$start_line" "$end_line
  fi
  
  echo $line_nr
}

# truncate and redirect specified logs with specified start line number and end line number to a specified dir
# param1: log file with absolute path
# param2: start seconds
# param3: end seconds
# param4: label string which used as file name to save logs
function cp_logs() {
  local start=$2
  local end=$(($3+1))
  local label=$4

  local logs=$(get_logs $1 $start)
  local start_line=""
  local end_line=""
  local upload_temppath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_temppath/) print $2}' | sed -e 's/[ \t\/]*$//')
  for var_log in ${logs[*]}; do
    local file_name="${var_log##*/}"
    local upper_path=$(echo $var_log| awk '{print toupper($0)}')
    # if it's ffdc or qmgr log, the just copy it
    if [[ "$upper_path" == *"FFDC"* || "$upper_path" == *"QMGR"* ]]; then
      cp $var_log $upload_temppath"/"$label"_"$file_name
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "copy file to $upload_temppath"/"$label"_"$file_name successfully" >> $first_log
      continue
    fi
    
    #local line_nr=$(get_line_nr $var_log $start $end)
    local line_nr=$(get_line_nr_bin $var_log $start $end)
    line_nr=( $line_nr )
    start_line=${line_nr[0]}
    end_line=${line_nr[1]}
    if [[ "$line_nr" == "" || "$start_line" == "" || "$end_line" == "" ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "couldn't get start and end line number in log $var_log" >> $first_log
      continue
    fi
    
    local line_tot=$(( $end_line-$start_line ))
    cat $var_log | tail -n +$start_line| head -$line_tot > $upload_temppath"/"$label"_"$file_name
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "truncate file to $upload_temppath"/"$label"_"$file_name successfully" >> $first_log
  done
}

# collect logs and compress them to a specified dir
# param1: json string like json string like {"start":213123131231,"end":23222333332121,"domain":"BIJS"}
# param2: domain name like "OVCP", "BIJS"...
# rerurn: compressed file names like "HOST_DOMAIN_TIMESTAMP.tgz"
function collect_logs() {
  local start=$(echo $1|awk -F "," 'END {for(i=1;i<=NF;i++) if($i ~/.*start.*/) print $i}' | awk -F ":" '{print $2}'| sed -e 's/[]}]*$//')
  local end=$(echo $1|awk -F "," 'END {for(i=1;i<=NF;i++) if($i ~/.*end.*/) print $i}' | awk -F ":" '{print $2}'| sed -e 's/[]}]*$//')
  local domain=$(echo $1|awk -F "," 'END {for(i=1;i<=NF;i++) if($i ~/.*domain.*/) print $i}' | awk -F ":" '{print $2}'| sed -e 's/[]}]*$//'| sed -e 's/"//g')

  #dummy for test
  domain="BIJS"
  start=1487873108
  end=1487984233
  
  if [[ "$domain" == "" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "domain parameter: $domain illegal" >> $first_log
    echo ""
    return 0
  fi  

  if (( "$start" > "$end" || "$start" <= 0 || "$end" <= 0 )); then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "start time($start) is bigger than end($end) or they are illegal" >> $first_log
    echo ""
    return 0
  fi

  local dir_list=$(cat $cfg | sed '/^\s*$/d' | sed -e 's/[\/*]$//' | awk -F "=" 'BEGIN {ORS = " "}  {if($1 ~/^logpath/) print $2}' | sed -e 's/[ \t]*$//')
  local lab_list=$(cat $cfg | sed '/^\s*$/d' | sed -e 's/[\/*]$//' | awk -F "=" 'BEGIN {ORS = " "}  {if($1 ~/^logpath/) print substr($1,9)}'| sed -e 's/[ \t]*$//')
  lab_list=( $lab_list )
  local i=0
  for var_dir in ${dir_list[*]}; do
    if [[ "$var_dir" != *"$domain"* ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "$var_dir not in domain $domain, not gonna collect its logs" >> $first_log
      i=$((i+1))
      continue
    fi
    if [[ "$(is_dir "$var_dir")" != "0" ]]; then
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "$var_dir is not a dir, not gonna collect its logs" >> $first_log
      i=$((i+1))
      continue
    fi  
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "collecting ${lab_list[$i]} $var_dir" >> $first_log
    $(cp_logs $var_dir $start $end ${lab_list[$i]})
    i=$((i+1))
  done

  local upload_temppath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_temppath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_filepath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_filepath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local file_name=$HOSTNAME"_"$domain"_"$(date +%s)"_"$RANDOM".tgz"
  
  if [[ "$(is_dir_null $upload_temppath)" == "0" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_warn ${FUNCNAME[0]} "no logs in $upload_temppath, not gonna compress" >> $first_log
    echo ""
    return 0
  fi
  
  cd $upload_temppath && tar -zcf $upload_filepath"/"$file_name *
  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "compress logs as $upload_filepath"/"$file_name successfully" >> $first_log
  rm -rf $upload_temppath/*
  echo $file_name
}

# post compressed tgz files to a remote server using curl
# param1: compressed tgz file name with absolute path
# param2: json str which contains upload id information
# return: 0 if successful, -1 if failed
function post_file() {
  local pfile=$1
  local fname="${pfile##*/}"
  local upload_endpoint=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_endpoint/) print $2}' | sed -e 's/[ \t\/]*$//')
  local id=$(echo $2|awk -F "," 'END {for(i=1;i<=NF;i++) if($i ~/.*_id.*/) print $i}' | awk -F ":" '{print $2}'| sed -e 's/[]}]*$//' | sed -e 's/"//g')
  upload_endpoint=$upload_endpoint"/"$id
  
  if [ "$(test_connectivity $upload_endpoint)" -ne "0" ]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "$upload_endpoint not available" >> $first_log
    echo -1
    return 0
  fi
  
  #local response=$(curl -sX POST -F "file=@$pfile" -F "fileName=$fname" $upload_endpoint)
  local response=$(curl -sX POST -F "logfile=@$pfile" $upload_endpoint)
  local upper_response=$(echo $response| awk '{print toupper($0)}')
  if [[ "$upper_response" == *"OK"* ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "post successfully: $response" >> $first_log
    rm -rf $pfile
    echo 0
  else
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "post failed: $response" >> $first_log
    echo -1
  fi 
}

# mv the compressed file which was failed to post to specified dir
# param1: compressed tgz file name with absolute path
function mv_failedpost(){
  local upload_filepath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_filepath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_failpath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_failpath/) print $2}' | sed -e 's/[ \t\/]*$//')
  mv $upload_filepath"/"$1 $upload_failpath
}

# preparation work
function init(){
  $(make_dir "$log_dir")
  $(make_file "$first_log")
  $(make_file "$cfg")

  local upload_temppath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_temppath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_filepath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_filepath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_failpath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_failpath/) print $2}' | sed -e 's/[ \t\/]*$//')
  
  $(make_dir "$upload_temppath")
  $(make_dir "$upload_filepath")
  $(make_dir "$upload_failpath")

  rm -rf $upload_temppath"/*"

  local upload_overdue=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_overdue/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_failpath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_failpath/) print $2}' | sed -e 's/[ \t\/]*$//')
  $(rm_overdue_files $upload_failpath $upload_overdue)
  
  local size=$(get_filesize "$first_log")
  if [[ "$size" -gt "$log_limit" ]]; then
    $(roll_log)
  fi

  printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "initialized" >> $first_log
}

function main() {
  $(init)

  local upload_temppath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_temppath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_filepath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_filepath/) print $2}' | sed -e 's/[ \t\/]*$//')
  local upload_failpath=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_failpath/) print $2}' | sed -e 's/[ \t\/]*$//')
  
  if [[ "$(is_dir $upload_temppath)" != "0" || "$(is_dir $upload_filepath)" != "0" || "$(is_dir $upload_failpath)" != "0" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "create $upload_temppath or $upload_filepath or $upload_failpath failed, not gonna collect logs" >> $first_log
    return 0
  fi

  local str=$(get_json)
  if [[ "$str" == "" || "$str" == "[]" ]]; then
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "no alert, no collecting logs" >> $first_log
    return 0
  fi
  
  local json_cnt=$(echo $str | awk -F ',{' 'END { print NF}')
  for ((i=1; i<=$json_cnt; i++)); do
    local json_str=$(echo $str | awk -F ',{' 'END {for(j=1;j<=NF;j++) print $j}'| tail -n +"$i"|head -1)
    printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_info ${FUNCNAME[0]} "json_str: $json_str" >> $first_log
    local gz_file=$(collect_logs "$json_str")
    local post_result=-1
    local upload_retry=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^upload_retry/) print $2}' | sed -e 's/[ \t]*$//')
    local retry_delay=$(cat $cfg | sed '/^\s*$/d' |awk -F "=" '{if($1 ~/^retry_delay/) print $2}' | sed -e 's/[ \t]*$//')
    
    if [[ "$gz_file" != "" ]]; then
      post_result=$(post_file $upload_filepath/$gz_file $json_str)
      for ((k=0; k<$(($upload_retry-1)); k++)); do
        if [[ "$post_result" == "0" ]]; then
          break;
        fi
        sleep $retry_delay
        post_result=$(post_file $upload_filepath/$gz_file $json_str)
      done
      
      if [[ "$post_result" != "0" ]]; then
        printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "failed after retrying $upload_retry times to upload logs" >> $first_log
        $(mv_failedpost $gz_file)
      fi  
    else
      printf "%s %-10s %-20s\t%s\n" "$(date +"%F %T:%3N")" $log_error ${FUNCNAME[0]} "failed to collect logs" >> $first_log
    fi
  done
}

$(main)
