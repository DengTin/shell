#!/bin/bash
SCRIPTPATH="`readlink -f $0`"
BASEDIR="`dirname $SCRIPTPATH`"
#PARENTDIR="`dirname "$BASEDIR"`"
#BINDIR="$PARENTDIR/bin"
#BINDIR="/usr/bin"
CFG="$BASEDIR/dir_monitor_list.cfg"
LOGDIR="$BASEDIR/logs"
ALERT_TIMES="$LOGDIR/dir_monitor_alert.txt"
LOG="$LOGDIR/dir_monitor.log"
LOG_BAK="$LOGDIR/dir_monitor.log.bak"
LOG_LIMIT="20971520"
LOG_INFO=" Info "
LOG_ERROR=" Error "
LOG_WARN=" Warning "


function is_dir() {
  if [[ -d "$1" ]]; then
    echo 0
  else
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": Directory $1 not existed" >> $LOG
    echo "Directory $1 not existed"
  fi
}

function is_dir_null() {
  if [ "$(ls -A $1)" ]; then
    echo -1
  else
    echo 0
  fi
}


function make_dir() {
  if [[ ! -d "$1" ]]; then
    mkdir -pm 755 "$1"
  fi
}

function make_file() {
  if [[ ! -f "$1" ]]; then
    touch "$1"
    chmod 777 "$1"
  fi
}

function list_dir() {
  local files=`ls -ALlt "$1"|tail -n +2`
  echo "$files"
}

function list_lastest_files() {
  local files=`ls -ALlt "$1"|tail -n +2|head -"$2"`
  echo "$files"
}

function list_the_file() {
  local i=$(( $2 + 1 ))
  local thefile=`ls -ALlt "$1"|tail -n +"$i"|head -1`
  echo "$thefile"
}

function list_the_file_with_path() {
  cd $1
  local thefile=`ls -t -d -1 $PWD/*.* |tail -n +$2 |head -1`
  echo "$thefile"
}

function get_file_seconds() {
  local seconds=`stat -c %Y $1`
  echo $seconds
}

# parameter example: "20160119"
function list_file_via_date() {
  local thefile=`ls -ALlt $1|tail -n +2|awk -v mydate="$2" '{datestr=$6" "$7" "$8; "date -d \""datestr"\" +%Y%m%d"|getline filedate; if(filedate == mydate) print $0}'`
  echo $thefile
}

function is_workingday() {
  if (( $1 >= 1 && $1 <= 5 )); then
    echo 0
  else
    echo -1
  fi
}

function check_cfg() {
  local result=`cat $CFG | sed '/^\s*$/d'|head -$1|tail -1| awk -F ':' '{for(i=0;i<5;i++){ if($i=="") {print $0;break} };if(NF != 5) print $0}'`
  if [[ "$result" != ""  ]]; then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": Format of $CFG is not correct: $result" >> $LOG
    echo "Format of $CFG is not correct: $result"
  else
    echo 0
  fi
}

function get_cfg_seconds() {
  if [[ "$2" == "d" ]]; then
    echo "$(($1 * 24 * 60 * 60))"
  elif [[ "$2" == "h" ]]; then
    echo "$(($1 * 60 * 60))"
  elif [[ "$2" == "m" ]]; then
    echo "$(($1 * 60))"
  else
    echo "$1"
  fi
}

function check_nfs() {
  local result=`cat /proc/mounts|awk -v nfs="$1" '{if($2 == nfs) print $0}'`
  if [[ "$result" == "" ]]; then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": $1 not mounted" >> $LOG
    echo "$1 not mounted"
  else
    echo 0
  fi
}

function check_file() {
  local dir_info=("$@")
  if (( $(is_dir_null "${dir_info[0]}") == 0 )); then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file under directory ${dir_info[0]}" >> $LOG
    echo "No file under directory ${dir_info[0]}"
    return 0
  fi

  local thefile=$(list_the_file_with_path "${dir_info[0]}" 1)
  local file_seconds=$(get_file_seconds "$thefile")

  local cfg_seconds=$(get_cfg_seconds "${dir_info[1]}" "${dir_info[2]}")
  local now_seconds=`date +%s`
  if (( $now_seconds - $file_seconds > $cfg_seconds )); then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile" >> $LOG
    echo "No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile"
  else
    echo 0
  fi
}

function check_ttrans() {
  local dir_info=("$@")
  if (( $(is_dir_null "${dir_info[0]}") == 0 )); then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file under directory ${dir_info[0]}" >> $LOG
    echo "No file under directory ${dir_info[0]}"
    return 0
  fi

  local thefile=$(list_the_file "${dir_info[0]}" 1)
  #local datestr=`echo $thefile|awk '{print $6,$7,$8}'`
  local datestr=`echo $thefile|awk '{day=substr($NF,18,10); hour=substr($NF,29,8); gsub("_","-",day); gsub("_",":",hour); print day, hour}'`
  local file_seconds=`date -d "$datestr" +%s`
  local cfg_seconds=$(get_cfg_seconds "${dir_info[1]}" "${dir_info[2]}")
  local now_seconds=`date +%s`
  if (( $now_seconds - $file_seconds > $cfg_seconds )); then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile" >> $LOG
    echo "No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile"
  else
    echo 0
  fi
}


function check_vptmos() {
  local dir_info=("$@")
  #local day_of_week=`date --date="1 days ago" +%u`
  local day_of_week=`date +%u`
  if (( $(is_workingday $day_of_week) != 0 )); then
    echo `date +%F" "%T`""$LOG_INFO""${FUNCNAME[0]}": Not working day, not gonna check" >> $LOG
    echo 0
    return 0
  fi

  #local result=$(check_file ${dir_info[@]})
  #echo $result

  if (( $(is_dir_null "${dir_info[0]}") == 0 )); then
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file under directory ${dir_info[0]}" >> $LOG
    echo "No file under directory ${dir_info[0]}"
    return 0
  fi

  #local thefile=$(list_the_file "${dir_info[0]}" 1)
  local thefile=$(list_the_file_with_path "${dir_info[0]}" 1)
  #local datestr=`echo $thefile|awk '{print $6,$7,$8}'`
  #local file_seconds=`date -d "$datestr" +%s`
  local file_seconds=$(get_file_seconds "$thefile")
  local cfg_seconds=$(get_cfg_seconds "${dir_info[1]}" "${dir_info[2]}")
  # if Monday, then should ignore weekends
  if (( $day_of_week == 1 )); then
    cfg_seconds=$(( cfg_seconds + 48*60*60 ))
  fi

  local now_seconds=`date +%s`
  if (( $now_seconds - $file_seconds > $cfg_seconds )); then
    # set format of thefile for logging
    thefile=$(list_the_file "${dir_info[0]}" 1)
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile" >> $LOG
    echo "No file update over ${dir_info[1]}${dir_info[2]} under directory ${dir_info[0]}: $thefile"
  else
    echo 0
  fi
}

function check_dir() {
  local dir_info=("$@")
  local seconds=$(get_cfg_seconds "${dir_info[1]}" "${dir_info[2]}")
  local files=$(list_dir "${dir_info[0]}")
  local existed_files_cnt=`echo "$files"|awk -v cnt="$seconds" '{if($1 ~/^-/) datestr[$9]=$6" "$7" "$8} END{j=0; for(i in datestr) {"date -d \""datestr[i]"\" +%s"|getline filedate; "date +%s"|getline nowdate; if(nowdate-filedate > cnt) {j++}} print j}'`
  #local existed_files_cnt=`echo "$files"|awk -v cnt="$seconds" '{datestr[$9]=$6" "$7" "$8} END{j=0; for(i in datestr) {"date -d \""datestr[i]"\" +%s"|getline filedate; "date +%s"|getline nowdate; if(nowdate-filedate > cnt) {j++}} print j}'`
  if [[ "$existed_files_cnt" != 0 ]]; then
    echo `date +%F" "%T`""$LOG_INFO""${FUNCNAME[0]}": The 5 oldest files:" >> $LOG
    echo "$files"|tail -5 >> $LOG
    echo `date +%F" "%T`""$LOG_ERROR""${FUNCNAME[0]}": There are $existed_files_cnt file backlog under directory ${dir_info[0]}" >> $LOG
    echo "There are $existed_files_cnt file backlog under directory ${dir_info[0]}"
  else
    echo 0
  fi
}

function get_filesize() {
  local size=$(stat -c%s "$1")
  echo "$size"
}

function truncate_log() {
  cat "$1" > "$2"; truncate "$1" --size 0
}

function main() {
  $(make_dir "$LOGDIR")
  $(make_file "$LOG")
  $(make_file "$LOG_BAK")
  $(make_file "$CFG")
  $(make_file "$ALERT_TIMES")
  
  local dir_list=`cat $CFG | sed '/^\s*$/d' |awk 'BEGIN {ORS = " "} {if($1 !~/^#/) print $0}'| sed -e 's/[ \t]*$//'`
  local err_str=""
  local temp_str=""
  local i=0
  for var in ${dir_list[*]}; do
    echo `date +%F" "%T`""$LOG_INFO""${FUNCNAME[0]}": Gonna check $var" >> $LOG

    # check cfg  
    i=$(( i+1 ))
    local result=$(check_cfg "$i")
    if [[ "$result" != "0" ]]; then
      if [[ "$err_str" != "" ]]; then
        err_str+=", "
      fi
      err_str+="$result"
      continue
    fi

    local dir_info=($(echo $var| awk  -F ':' '{print $2, $3, $4}'))
    local label=$(echo $var| awk  -F ':' '{print $1}')
    local times_cfg=$(echo $var| awk  -F ':' '{print $5}')

    # check if directory exists, don't check NFS cause it might stuck when the NFS didn't work
    if [[ "$label" != *"nfs"* ]]; then
      result=$(is_dir "${dir_info[0]}")
      if [[ "$result" != "0" ]]; then
        if [[ "$err_str" != "" ]]; then
          err_str+=", "
        fi
        err_str+="$result"
        continue
      fi
    fi
    
    if [[ "$label" == *"Ttrans"* ]]; then
      result=$(check_ttrans ${dir_info[@]})
    elif [[ "$label" == *"VPT-MOS"* ]]; then
      result=$(check_vptmos ${dir_info[@]})
    elif [[ "$label" == *"nfs"* ]]; then
      result=$(check_nfs ${dir_info[0]})
    else
      result=$(check_dir ${dir_info[@]})
    fi

    local times_row=$(cat $ALERT_TIMES|sed '/^\s*$/d'|awk -F ":" -v dir_info="${dir_info[0]}" '{if($1 == dir_info) print $2}')
    if [[ "$times_row" == "" ]]; then
      times_row=0
    fi

    if [[ "$result" == "0" ]]; then
      echo `date +%F" "%T`""$LOG_INFO""${FUNCNAME[0]}": Dir ${dir_info[0]} check result:OK" >> $LOG
    elif (( $times_row >= $times_cfg - 1 )); then
      if [[ "$err_str" != "" ]]; then
        err_str+=", "
      fi
      err_str+="$result"
    else
      times_row=$(( $times_row+1 ))
      temp_str+=${dir_info[0]}":"$times_row"\n"
    fi
  done

  # record alert times
  echo -e $temp_str > $ALERT_TIMES
  
  echo `date +%F" "%T`""$LOG_INFO""${FUNCNAME[0]}": Have checked $i directories" >> $LOG
  
  local log_size=$(get_filesize "$LOG")
  if [[ "$log_size" -gt "$LOG_LIMIT" ]]; then
    $(truncate_log "$LOG" "$LOG_BAK")
  fi

  if [[ "$err_str" != "" ]]; then
    # print str to stdout to invoke tivoli alert
    echo "DIR_Alert|"`date +%Y-%m-%d" "%k:%M:%S`"|"$err_str
  fi
}

result=$(main)
if [[ "$result" != "" ]]; then
  echo $result
fi
