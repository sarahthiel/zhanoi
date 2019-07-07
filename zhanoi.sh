#!/usr/bin/env bash

# This file is licensed under the MIT license.
# See the AUTHORS and LICENSE files for more information.
#
# repository:       https://github.com/sebastianthiel/zhanoi
# bug tracking:     https://github.com/sebastianthiel/zhanoi/issues


########################################
# GLOBALS                              #
########################################
ZFS_CMD='/sbin/zfs'         # path to zfs command
SCRIPTNAME="${0##*/}"       # name of program
VERBOSE=0                   # enable verbose output
DRY=0                       # enable dry run
DEFAULTPREFIX="$SCRIPTNAME" #default prefix
DEFAULTDATEFORMAT="%y%m%d.%H%M" #default dateformat
DEFAULTTAPES="2" #default tapes

########################################
# HELPER FUNCTIONS                     #
########################################
# output error and exit
die() {
	echo "$@" >&2
	exit 1
}

# execute a command
exec() {
	[[ $VERBOSE -eq 1 ]] && echo $1
	[[ $DRY -eq 0 ]] && `$1`
}

# remove leading and tailing quotes from value
remove_quotes() {
	local tmp=$1
	tmp="${tmp%\"}"
	echo "${tmp#\"}"
}

# find the most significant bit of a number
# returns the position of that bit
find_most_significant_bit() {
	local number=$1
	local bitpos=0
	while [[ $number -ne 0 ]]
	do
		bitpos=$((bitpos + 1))
		number=$((number>>1))
	done
	echo $bitpos
}

# calculate active set by a sequence number
find_tape_by_sequence() {
	local sequence=$1
	local next=$((sequence+1))
	local diff=$((sequence^next))
	find_most_significant_bit $diff
}

# check if a filesystem exists
# return 1 if filesystem does not exist
filesystem_exists() {
	local fs=$1
	local list=$($ZFS_CMD list -H -o name)
    local i
    for i in $list; do
        [[ "$fs" = "$i" ]] && return 0
    done

    return 1
}

# create a snapshot
snapshot_fs(){
	local fs=$1
	local recursive=$2
	local prefix=$3

	filesystem_exists "$fs" || die "'$fs' does not exist!"
	get_skip $fs $prefix || return 0

	# read config from fs metadata
	local tapes=$(get_tape_count $fs $prefix)
	local sequence=$(get_sequence $fs $prefix)
	local dateformat=$(get_dateformat $fs $prefix)

	[[ "$tapes" = "-" ]] || [[ "$sequence" = "-" ]] || [[ "$dateformat" = "-" ]] && die "'$fs' is not correctly Initialized"

	local current_set=$(find_tape_by_sequence $sequence)
	local obsolete="$($ZFS_CMD list -H -o name -t snapshot | grep -e "^$fs\@$SCRIPTNAME-.*-t$current_set$")"

	local date=$(date "+$dateformat")
	local snapname="$SCRIPTNAME-$prefix-$date-t$current_set"
	exec "$ZFS_CMD snapshot $fs@$snapname"

	# if recursive is set, snapshot children
	if [[ $recursive -eq 1 ]]
	then
		local children="$($ZFS_CMD list -H -o name -t filesystem | grep -e "^$fs/[^\/]\+$")"
		for c in $children; do
			snapshot_fs $c 1 $prefix
		done
	fi

	# delete old snapshot from set
	local os
    for os in $obsolete; do
    	exec "$ZFS_CMD destroy $os"
    done

	# increment and store sequence
	sequence=$((sequence + 1))
	[[ $tapes -eq $current_set ]] && sequence=0
	set_sequence $sequence $fs $prefix
}

########################################
# GETTER // SETTER                     #
########################################
set_config_value() {
	local parameter=$1
	local value=$2
	local fs=$3
	local prefix=$4

	exec "$ZFS_CMD set $SCRIPTNAME:$prefix:$parameter=\"$value\" $fs"
}

get_config_value() {
	local parameter=$1
	local fs=$2
	local prefix=$3
	echo $(remove_quotes $($ZFS_CMD get -H -o value $SCRIPTNAME:$prefix:$parameter $fs))
}

set_tape_count(){
	local value=$1
	local fs=$2
	local prefix=$3
		[[ $value -lt 1 ]] || [[ $value -gt 31 ]] && die "tapes must be between 1 and 31"
	set_config_value "tapes" $value $fs $prefix
}

get_tape_count(){
	local fs=$1
	local prefix=$2
	get_config_value "tapes" $fs $prefix
}

set_sequence(){
	local value=$1
	local fs=$2
	local prefix=$3
	set_config_value "sequence" $value $fs $prefix
}

get_sequence(){
	local fs=$1
	local prefix=$2
	get_config_value "sequence" $fs $prefix
}

set_dateformat(){
	local value=$1
	local fs=$2
	local prefix=$3
	set_config_value "dateformat" $value $fs $prefix
}

get_dateformat(){
	local fs=$1
	local prefix=$2
	get_config_value "dateformat" $fs $prefix
}

set_skip(){
	local value=$1
	local fs=$2
	local prefix=$3

	case $value in
		0) set_config_value "skip" "-" $fs $prefix;;
		1) set_config_value "skip" "On" $fs $prefix;;
	esac
}

get_skip(){
	local fs=$1
	local prefix=$2

	local value=$(get_config_value "skip" $fs $prefix)
	case $value in
		0|Off|False|false|-) return 0 ;;
		1|On|True|true) return 1 ;;
	esac
	die "invalid value"
}


########################################
# COMMANDS                             #
########################################
# output help text and exit
cmd_help() {
  cat << EOF
Usage:
    $SCRIPTNAME init [--tapes,-t NumberOfTapes] [--dateformat,-d DateFormat] [--prefix,-p Prefix] [-n] [--verbose, -v] zpool/filesystem
        Initialize filesystem

    $SCRIPTNAME set [--tapes,-t NumberOfTapes] [--dateformat,-d DateFormat] [--prefix,-p Prefix] [--skip,-s] [--no-skip,-S] [-n] [--verbose, -v] zpool/filesystem
        set configuration parameter for filesystem

    $SCRIPTNAME snapshot [--prefix,-p Prefix] [-r] [-n] [--verbose, -v] zpool/filesystem
        create a snapshot


More information may be found in the man page.
EOF
  exit 0
}

# initialize a filesystem
cmd_init() {
	local tapes=$DEFAULTTAPES #default number of tapes
	local dateformat=$DEFAULTDATEFORMAT # default date format
	local prefix="$DEFAULTPREFIX" #default prefix

	opts="$(getopt -o t:nvd:p: -l tapes:,verbose,dateformat:,prefix: -n "$SCRIPTNAME" -- "$@")"
	local err=$?
	eval set -- "$opts"

	while true;do
	    case $1 in
            -t|--tapes) tapes="$2"; shift 2 ;;
            -p|--prefix) prefix="$2"; shift 2 ;;
            -d|--dateformat) dateformat="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -n) DRY=1; shift ;;
            --) shift; break ;;
	    esac
	done
	fs=$1

	[[ $err -ne 0 ]] && cmd_help
	filesystem_exists "$fs" || die "'$fs' does not exist!"

	set_tape_count $tapes $fs $prefix
	set_sequence 0 $fs $prefix
	set_dateformat $dateformat $fs $prefix
}

# update configuration
cmd_set(){
	local tapes=''      #default number of tapes
	local dateformat='' # default date format
	local prefix="$DEFAULTPREFIX"     #default prefix
	local skip=''       #skip filesystem

	opts="$(getopt -o t:nvd:p:sS -l tapes:,verbose,dateformat:,prefix:,skip,no-skip -n "$SCRIPTNAME" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do
        case $1 in
            -t|--tapes) tapes="$2"; shift 2 ;;
            -p|--prefix) prefix="$2"; shift 2 ;;
            -d|--dateformat) dateformat="$2"; shift 2 ;;
            -s|--skip) skip=1; shift ;;
            -S|--no-skip) skip=0; shift ;;
            --verbose) VERBOSE=1; shift ;;
            -n) DRY=1; shift ;;
            --) shift; break ;;
        esac
    done
	fs=$1
	[[ $err -ne 0 ]] && cmd_help
	filesystem_exists "$fs" || die "'$fs' does not exist!"

	[[ "$tapes" != "" ]] && set_tape_count $tapes $fs $prefix
	[[ "$dateformat" != "" ]] && set_dateformat $dateformat $fs $prefix
	[[ "$skip" != "" ]] && set_skip $skip $fs $prefix
}

# make a snapshot
cmd_snapshot() {
	local recursive=0
	local prefix="$DEFAULTPREFIX"     #default prefix

	opts="$(getopt -o rnv -l verbose -n "$SCRIPTNAME" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do
        case $1 in
            -p|--prefix) prefix="$2"; shift 2 ;;
            -r) recursive=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -n) DRY=1; shift ;;
            --) shift; break ;;
        esac
    done
	fs=$1

	[[ $err -ne 0 ]] && cmd_help
	snapshot_fs $fs $recursive $prefix
}

########################################
# MAIN                                 #
########################################
case "$1" in
  help|--help|-h) shift; cmd_help "$@" ;;
  init|i)     shift; cmd_init "$@" ;;
  set)     shift; cmd_set "$@" ;;
  snapshot|s)         shift; cmd_snapshot "$@" ;;
  *)                     cmd_help "$@" ;;
esac

exit 0
