#!/bin/bash
SCRIPTPATH="`readlink -f $0`"
BASEDIR="`dirname $SCRIPTPATH`"
LOG_NAME="cpu_process_monitor_""$HOSTNAME"".log"
LOG_BAK_NAME="$LOG_NAME"".bak"
LOG_PID_NAME="pid_""$HOSTNAME"".log"
LOG_PNAME_NAME="pname_""$HOSTNAME"".log"

LOG="$BASEDIR""/logs/""$LOG_NAME"
LOG_BAK="$BASEDIR""/logs/""$LOG_BAK_NAME"
LOG_PID="$BASEDIR""/logs/""$LOG_PID_NAME"
LOG_PNAME="$BASEDIR""/logs/""$LOG_PNAME_NAME"
LOG_LIMIT="10485760"

function get_filesize() {
  local size=$(stat -c%s "$1")
  echo "$size"
}

function truncate_log() {
  `cat "$1" > "$2"; truncate "$1" --size 0`
}

while (true); do
  echo "*******start to check at `date +%Y-%m-%d_%H:%M:%S`" >> $LOG
  top -bn 1|sed '1,7d'|sort -nrk 9|head -5|awk '{print $9,$10,$1,$2,$NF}' > $LOG_PID
  pids=`cat $LOG_PID |awk 'BEGIN {ORS = " "} {print $3}'|sed 's/,*$//g'`
  for pid in ${pids[*]}; do
    pname=`ps -p $pid -f|sed 1d|awk '{if($0 != "") {print $8,$NF}}'`
    if [[ "$pname" == "" ]]; then
      echo "NoSuchProcess" >> $LOG_PNAME
    else
      echo "$pname" >> $LOG_PNAME
    fi
  done
  paste -d " " $LOG_PID $LOG_PNAME >> $LOG
  truncate "$LOG_PNAME" --size 0
  LOGSIZE=$(get_filesize "$LOG")
  if [[ "$LOGSIZE" -gt "$LOG_LIMIT" ]]; then
    $(truncate_log "$LOG" "$LOG_BAK")
  fi
  echo "*******done" >> $LOG
  sleep 5s
done
