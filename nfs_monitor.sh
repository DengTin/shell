#!/bin/bash
SCRIPTPATH="`readlink -f $0`"
BASEDIR="`dirname $SCRIPTPATH`"
#PARENTDIR="`dirname "$BASEDIR"`"
#BINDIR="$PARENTDIR/bin"
#BINDIR="/usr/bin"
LOGDIR="$BASEDIR/logs"
CFG="$BASEDIR/nfs_monitor_list.cfg"
LOG="$LOGDIR/nfs_monitor.log"
LOG_BAK="$LOGDIR/nfs_monitor.log.bak"
LOG_LIMIT="20971520"

function make_dir() {
  if [[ ! -d "$1" ]]; then
    mkdir -m 777 "$1"
  fi
}

function check_nfs() {
  local nfs=("$@")
  local result=""
  for v in ${nfs[*]}; do
    local temp=`cat /proc/mounts|awk -v key="$v" '{if($2 == key) print $0}'`
    if [[ "$temp" == "" ]]; then
      result+=$v","
    fi
  done
  if [[ "$result" != "" ]]; then
    result="NFS "`echo $result| sed 's/,$//'`" not mounted"
    echo "NFS_Check|`date +"%Y-%m-%d %k:%M:%S"`|"$result
  else
    echo 0
  fi
}

function make_file() {
  if [[ ! -f "$1" ]]; then
    touch "$1"
    chmod 777 "$1"
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
NFSLIST=`cat $CFG | sed '/^\s*$/d' |awk 'BEGIN {ORS = " "} {if($1 !~/^#/) print $0}'| sed -e 's/[ \t]*$//'`
RESULT=$(check_nfs $NFSLIST)
if [[ "$RESULT" != "0" ]]; then
  echo $RESULT | tee -a $LOG
else
  echo "NFS_Check|`date +"%Y-%m-%d %k:%M:%S"`|Normal" >> $LOG
fi
