#!/bin/bash
SCRIPTPATH="`readlink -f $0`"
BASEDIR="`dirname $SCRIPTPATH`"
PARENTDIR="`dirname "$BASEDIR"`"
#BINDIR="$PARENTDIR/bin"
BINDIR="/usr/bin"
CFG="$BASEDIR/ftp_list.cfg"
LOGDIR="$BASEDIR/logs"
ALERT_TIMES="$LOGDIR/ftp_monitor_alert.txt"
TXT="$LOGDIR/ftp_ls.txt"
LOG="$LOGDIR/ftp_monitor.log"
LOG_BAK="$LOGDIR/ftp_monitor.log.bak"
LOG_LIMIT="20971520"
FTPINFO=()

function make_dir() {
  if [[ ! -d "$1" ]]; then
    mkdir -m 777 "$1"
  fi
}

function make_file() {
  if [[ ! -f "$1" ]]; then
    touch "$1"
    chmod 777 "$1"
  fi
}

# return 0 if ip is accessible
function check_ip() {
  local result=`ping -c 1 -W 1 $1 2>/dev/null| awk 'match($0, /[0-9]+% packet loss/) {print substr($0, RSTART, index($0, "%")-RSTART)}'`
  if [[ "$result" =~ "unknown" ]] || [[ "$result" == "" ]]; then
    echo -1
  else
    echo $result
  fi
}

# return 1 if port is not accessible
function check_port() {
  local result=`nc -w 5 $1 $2 &>/dev/null; echo $?`
  if [[ "$result" != "0"  ]]; then
    result=1
  fi
  echo $result
}

function check_ftpcfg() {
  local result=`cat $CFG | sed '/^\s*$/d'|head -$1|tail -1| awk -F ':' '{for(i=0;i<9;i++){ if($i=="") {print $0;break} };if(NF != 9) print $0}'`
  if [[ "$result" != ""  ]]; then
    echo "Format of $CFG is not correct, $result"
  else
    echo 0
  fi
}

function check_ftp_os() {
  local linux_file=("-" "d" "c" "b" "s" "p" "l")
  if [[ "$1" =~ ^[0-9]+.* ]]; then
    echo "NT"
  else
    for i in ${linux_file[@]}; do
      if [[ "$1" =~ ^"$i"+.* ]]; then
        echo "LINUX"
        break
      fi
    done
  fi
}

function ftp_ls() {
  local ftp_info=("$@")
  local result=`
    $BINDIR/ftp -n ${ftp_info[0]}  <<END_FTP
    quote USER ${ftp_info[3]}
    quote PASS ${ftp_info[4]}
    cd ${ftp_info[5]}
    ls
    quit
END_FTP`
  echo $result|xargs
}

function sftp_ls(){
  local ftp_info=("$@")
  export SSHPASS=${ftp_info[4]}
  local result=`$BINDIR/sshpass -e sftp -oBatchMode=no -b - ${ftp_info[3]}@${ftp_info[0]} 2>/dev/null << END_FTP
    cd ${ftp_info[5]}
    ls -l
    bye
END_FTP`
  echo $result|awk '{str=substr($0,index($0,"sftp> ls")+12); print substr(str,1,index(str,"sftp> bye")-2)}'|xargs
}

function compare_date() {
  local ftp_info=("$@")
  local seconds
  if [[ "${ftp_info[7]}" == "d" ]]; then
    seconds=`echo "$((${ftp_info[6]} * 24 * 60 * 60))"`
  elif [[ "${ftp_info[7]}" == "h" ]]; then
    seconds=`echo "$((${ftp_info[6]} * 60 * 60))"`
  elif [[ "${ftp_info[7]}" == "m" ]]; then
    seconds=`echo "$((${ftp_info[6]} * 60))"`
  else
    seconds="${ftp_info[6]}"
  fi

  local os=$(check_ftp_os "`cat $TXT`")
  if [[ "$os" == "LINUX" ]]; then
    local existed_files_cnt=`cat $TXT |xargs -n9|awk -v cnt="$seconds" '{if($1 !~/^d/) datestr[$9]=$6" "$7" "$8} END{j=0; for(i in datestr) {"date -d \""datestr[i]"\" +%s"|getline filedate; "date +%s"|getline nowdate; if(nowdate-filedate > cnt) {j++}} print j}'`
  elif [[ "$os" == "NT" ]]; then
    local existed_files_cnt=`cat $TXT |xargs -n4|awk -v cnt="$seconds" '{datestr[$4]=substr($1,7,2)"-"substr($1,1,2)"-"substr($1,4,2)" "$2} END{j=0; for(i in datestr) {"date -d \""datestr[i]"\" +%s"|getline filedate; "date +%s"|getline nowdate; if(nowdate-filedate > cnt) {j++}} print j}'`
  else
    :
  fi
  if [[ "$existed_files_cnt" != 0 ]]; then
    echo "There are $existed_files_cnt file backlog on ftp server ${ftp_info[0]} under directory ${ftp_info[5]}"
  else
    echo 0
  fi
}

function echo_ftp_ls() {
  if [[ "$1" == *"Not connected"* ]]; then
    echo "Ftp server ${FTPINFO[0]} not accessible now, $1"
  elif [[ "$1" == *"incorrect"* ]] || [[ "$1" == *"Not logged"* ]] || [[ "$1" == *"cannot log in"* ]]; then
    echo "Password of user ${FTPINFO[3]} is not correct on ftp server ${FTPINFO[0]}"
  elif [[ "$1" == *"directory"* ]] || [[ "$1" == *"cannot find"* ]]; then
    echo "Directory ${FTPINFO[5]} not exists on ftp server ${FTPINFO[0]}"
  elif [[ "$1" == "" ]]; then
    #echo "No file exists, ftp normal"
    :
  else
    echo "$1" > $TXT
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

$(make_dir "$LOGDIR")
$(make_file "$LOG")
$(make_file "$TXT")
$(make_file "$LOG_BAK")
$(make_file "$CFG")
$(make_file "$ALERT_TIMES")

FTPLIST=`cat $CFG | sed '/^\s*$/d' |awk 'BEGIN {ORS = " "} {if($1 !~/^#/) print $0}'| sed -e 's/[ \t]*$//'`
i=0

errorStr=""
tempStr=""

for var in ${FTPLIST[*]}; do
  # check ftp cfg
  i=`expr $i + 1`
  CHECKCFG=$(check_ftpcfg "$i")
  if [[ "$CHECKCFG" != "0" ]]; then
    #echo $CHECKCFG | tee -a $LOG
    echo $CHECKCFG >> $LOG
    errorStr+="$CHECKCFG"
    continue
  fi

  # get cfg
  FTPINFO=(`echo $var| awk  -F ':' '{print $1, $2, $3, $4, $5, $6, $7, $8}'`)
  times_cfg=$(echo $var| awk  -F ':' '{print $9}')
  TEMP=${FTPINFO[0]}"|"${FTPINFO[3]}"|"${FTPINFO[4]}"|"${FTPINFO[5]}
  times_row=$(cat $ALERT_TIMES|sed '/^\s*$/d'|awk -F ":" -v FTPINFO="$TEMP" '{if($1 == FTPINFO) print $2}')
  if [[ "$times_row" == "" ]]; then
    times_row=0
  fi

  # check ip:port availablity with specified alert times
  echo "ftp: ""${FTPINFO[0]} ${FTPINFO[1]} ${FTPINFO[3]}" >> $LOG
  if [[ $(check_port ${FTPINFO[0]} ${FTPINFO[1]}) == "1" ]]; then
    echo "${FTPINFO[0]}:${FTPINFO[1]} are not accessible now" >> $LOG
    if (( $times_row >= $times_cfg - 1 )); then
      if [[ "$errorStr" != "" ]]; then
        errorStr+=", "
      fi
      errorStr+="${FTPINFO[0]}:${FTPINFO[1]} are not accessible now"
    else
      times_row=$(( $times_row+1 ))
      temp_str+=${FTPINFO[0]}"|"${FTPINFO[3]}"|"${FTPINFO[4]}"|"${FTPINFO[5]}":"$times_row"\n"
    fi
    continue
  fi

  # get ftp 'ls' result
  if [[ "${FTPINFO[2]}" == "sftp" ]]; then
    FTPFILE=$(sftp_ls ${FTPINFO[@]})
  elif [[ "${FTPINFO[2]}" == "ftp" ]]; then
    FTPFILE=$(ftp_ls ${FTPINFO[@]})
  else
    echo "The ${FTPINFO[2]} protocol is not supported yet" >> $LOG
    if [[ "$errorStr" != "" ]]; then
      errorStr+=", "
    fi
    errorStr+="The ${FTPINFO[2]} protocol is not supported yet"
  fi

  #echo "FTPfile: ""$FTPFILE"
  # check ftp ls result, if no file then normal, if have file, then check the timestamp
  RESULT=$(echo_ftp_ls "$FTPFILE")
  if [[ "$RESULT" == "0" ]]; then
    TEMP=$(compare_date ${FTPINFO[@]})
    if [[ "$TEMP" != "0" ]]; then
      echo $TEMP >> $LOG
      if [[ "$errorStr" != "" ]]; then
        errorStr+=", "
      fi
      errorStr+="$TEMP"
    else
      echo "FTP_Check_Result|`date +"%Y-%m-%d %k:%M:%S"`|Normal" >> $LOG
    fi
    truncate $TXT --size 0
  elif [[ "$RESULT" != "" ]]; then
    echo "$RESULT" >> $LOG
    if [[ "$errorStr" != "" ]]; then
      errorStr+=", "
    fi
    errorStr+="$RESULT"
  else
    echo "FTP_Check_Result|`date +"%Y-%m-%d %k:%M:%S"`|Normal" >> $LOG
  fi
  #sleep 3
done

# record alert times
echo -e $temp_str > $ALERT_TIMES

if [[ "$errorStr" != "" ]]; then
  echo "FTP_Alert|`date +"%Y-%m-%d %k:%M:%S"`|$errorStr"
fi

echo "---------------------Have sent $i ftp request at `date +"%Y-%m-%d %k:%M:%S"`------------------------" >> $LOG
LOGSIZE=$(get_filesize "$LOG")
if [[ "$LOGSIZE" -gt "$LOG_LIMIT" ]]; then
  $(truncate_log "$LOG" "$LOG_BAK")
fi
