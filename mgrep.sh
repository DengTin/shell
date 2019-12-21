#!/bin/bash
#Joey
#used to grep a keyword in multiple files

# check if $logdir exists or accessible
function checklogdir() {
	if [ ! -d "$logdir" ]; then
        mkdir -m 755 -p "$logdir"
        echo "making directory $logdir"
    fi
    if [ ! -x "$logdir" ]; then
        echo "No access to $logdir"
        exit 1
    fi
}

function help() {
	echo "Usage: $0 -d dir [-f file1[+file2...]] -k keyword1[+keyword2...]"
}

function getoptions() {
    while getopts "d:k:hf:" arg
    do
        case $arg in
        "h")
            help
            exit 0
            ;;        
        "d")
            dir=$OPTARG
            ;;
        "k")
            key=$OPTARG
            ;;
        "f")
            file=$OPTARG
            ;;  
	    "?")
            echo "unknow argument"    
            exit 1
            ;;
        ":")
            echo "No argument value for option $OPTARG"
            exit 1
            ;;
        *)
            echo "Unknown error while processing options"
            exit 1
            ;;
        esac
    done
    if [ "$dir" == "" ] || [ "$key" == "" ]; then
        help
        exit 1
    fi
}

# get all dirs in a specified dir
function getdir() {
	local result=`ls -l $1|/usr/xpg4/bin/awk '{if($1 ~/^d/) printf "%s ", $NF}'`
	local i=0
	for var in ${result[*]}; do
	    result[$i]=$1"/"$var
	    i=`expr $i + 1`
	done
	echo ${result[*]}
}

# get all files in a specified dir
function getfile() {
	local result=`ls -l $1|/usr/xpg4/bin/awk '{if($1 ~/^-/) \
	    printf "%s ", $NF}'`
	local i=0
	for var in ${result[*]}; do
	    result[$i]=$1"/"$var
	    i=`expr $i + 1`
	done
	echo ${result[*]}
}

# if not null return 1 else 0
function isnotnull() {
	if [ "$1" != "" ] && [ "$1" != "\n" ] && \
	    [ "$1" != "\t" ]; then
	    echo 1
	else
	    echo 0
	fi        
}

# return an array of elements exist in both $1 and $2
function getthefile() {
	# use array as parameter
	eval source=(\${$1[@]})
	eval specifies=(\${$2[@]})
	local thefiles=()
	local tmp
	for specvar in ${specifies[*]}; do
	    tmp=`echo "${source[*]}"| /usr/xpg4/bin/awk 'BEGIN{OFS="\n"} \
	        {NF=NF; print $0}'| grep .*$specvar.*`
	    if [ $(isnotnull "$tmp") -eq 1 ]; then
	        thefiles=("${thefiles[@]}" "$tmp")
	    fi
	done
	echo "${thefiles[@]}" 
}

dir=""
key=""
file=""
logdir="/tmp/IBMChina/log-analysis"
getoptions $@
file=(`echo ${file//+/ }`)
key="`echo ${key//+/ }`"
checklogdir

if [ ! -x "$dir" ]; then
    echo "$dir not exist or no permission"
    exit 1
fi
cd $dir

alldirs=()
allfiles=()

tmpdir=($PWD)
while : 
do
    tmpmerg=()
    for dirvar in ${tmpdir[@]}; do
	    tmp=$(getdir "$dirvar")
	    tmpmerg=("${tmpmerg[@]}" "${tmp[@]}")
	    alldirs=("${alldirs[@]}" "${tmp[@]}")
	    tmpfile=$(getfile "$dirvar")
        allfiles=("${allfiles[@]}" "${tmpfile[@]}")
    done
    tmpdir="${tmpmerg[@]}"
    if [ "$tmpdir" == "" ]; then
        #echo "gonna break"
        break
    fi
done    

if [ "$file" == "" ]; then
    tmp=(${allfiles[@]})
else
    # only grep in specfied files
    tmp=$(getthefile allfiles file)
fi
  
for var in ${tmp[@]}; do
    # handle .gz files
    if [[ "$var" =~ .gz$ ]]; then
        gunzip -c "$var" > "$logdir/${var##*/}".log
        echo "-----------grep result of \"$key\" in $var: "
        more "$logdir/${var##*/}".log| grep -in "$key"
        rm -rf "$logdir/${var##*/}".log
    else
        echo "-----------grep result of \"$key\" in $var: "
        more "$var"| grep -in "$key"
    fi
done
