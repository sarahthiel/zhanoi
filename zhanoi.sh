#!/usr/bin/env bash

# This file is licensed under the MIT license.
# See the AUTHORS and LICENSE files for more information.
#
# repository:       https://github.com/sebastianthiel/zhanoi
# bug tracking:     https://github.com/sebastianthiel/zhanoi/issues


########################################
# GLOBALS                              #
########################################
ZFS_CMD='/sbin/zfs'      # path to zfs command
SCRIPTNAME="${0##*/}"    # name of program
VERBOSE=0                # enable verbose output
DRY=0                    # enable dry run

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
	filesystem_exists "$fs" || die "'$fs' does not exist!"
	get_skip $fs || return 0

	# read config from fs metadata
	local tapes=$(get_tape_count $fs)
	local sequence=$(get_sequence $fs)
	local dateformat=$(get_dateformat $fs)
	local prefix=$(get_prefix $fs)

	[[ "$tapes" = "-" ]] || [[ "$sequence" = "-" ]] || [[ "$dateformat" = "-" ]] || [[ "$prefix" = "-" ]] && die "'$fs' is not correctly Initialized"

	local current_set=$(find_tape_by_sequence $sequence)
	local obsolete="$($ZFS_CMD list -H -o name -t snapshot | grep -e "^$fs\@$SCRIPTNAME-.*-s$current_set$")"

	local date=$(date "+$dateformat")
	local snapname="$prefix-$date-s$current_set"
	exec "$ZFS_CMD snapshot $fs@$snapname"

	# if recursive is set, snapshot children
	if [[ $recursive -eq 1 ]]
	then
		local children="$($ZFS_CMD list -H -o name -t filesystem | grep -e "^$fs/[^\/]\+$")"
		for c in $children; do
			snapshot_fs $c 1
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
	set_sequence $sequence $fs
}

########################################
# GETTER // SETTER                     #
########################################
set_config_value() {
	local parameter=$1
	local value=$2
	local fs=$3

	exec "$ZFS_CMD set zhanoi:$parameter=\"$value\" $fs"
}

get_config_value() {
	local parameter=$1
	local fs=$2
	echo $(remove_quotes $($ZFS_CMD get -H -o value zhanoi:$parameter $fs))
}

set_tape_count(){
	local value=$1
	local fs=$2
		[[ $value -lt 1 ]] || [[ $value -gt 31 ]] && die "tapes must be between 1 and 31"
	set_config_value "tapes" $value $fs
}

get_tape_count(){
	local fs=$1
	get_config_value "tapes" $1
}

set_sequence(){
	local value=$1
	local fs=$2

	set_config_value "sequence" $value $fs
}

get_sequence(){
	local fs=$1
	get_config_value "sequence" $1
}

set_dateformat(){
	local value=$1
	local fs=$2

	set_config_value "dateformat" $value $fs
}

get_dateformat(){
	local fs=$1
	get_config_value "dateformat" $1
}

set_prefix(){
	local value=$1
	local fs=$2

	set_config_value "prefix" $value $fs
}

get_prefix(){
	local fs=$1
	get_config_value "prefix" $1
}

set_skip(){
	local value=$1
	local fs=$2
	case $value in
		0) set_config_value "skip" "-" $fs ;;
		1) set_config_value "skip" "On" $fs ;;
	esac
}

get_skip(){
	local fs=$1
	local value=$(get_config_value "skip" $1)
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

    $SCRIPTNAME snapshot [-r] [-n] [--verbose, -v] zpool/filesystem
        create a snapshot


More information may be found in the man page.
EOF
  exit 0
}

# initialize a filesystem
cmd_init() {
	local tapes=2 #default number of tapes
	local dateformat="%Y-%m-%d_%H.%M" # default date format
	local prefix="$SCRIPTNAME" #default prefix

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

	set_tape_count $tapes $fs
	set_sequence 0 $fs
	set_prefix $prefix $fs
	set_dateformat $dateformat $fs
}

# update configuration
cmd_set(){
	local tapes=''      #default number of tapes
	local dateformat='' # default date format
	local prefix=''     #default prefix
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

	[[ "$tapes" != "" ]] && set_tape_count $tapes $fs
	[[ "$prefix" != "" ]] && set_prefix $prefix $fs
	[[ "$dateformat" != "" ]] && set_dateformat $dateformat $fs
	[[ "$skip" != "" ]] && set_skip $skip $fs
}

# make a snapshot
cmd_snapshot() {
	local recursive=0

	opts="$(getopt -o rnv -l verbose -n "zhanoi" -- "$@")"
	local err=$?
	eval set -- "$opts"
	while true; do
        case $1 in
            -r) recursive=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -n) DRY=1; shift ;;
            --) shift; break ;;
        esac
    done
	fs=$1

	[[ $err -ne 0 ]] && cmd_help
	snapshot_fs $fs $recursive
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
