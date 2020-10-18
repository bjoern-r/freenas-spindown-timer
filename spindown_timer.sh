#!/usr/bin/env bash

# ##################################################
# FreeNAS HDD Spindown Timer
# Monitors drive I/O and forces HDD spindown after a given idle period.
#
# Version: 1.3.1
#
# See: https://github.com/ngandrass/freenas-spindown-timer
#
#
# MIT License
# 
# Copyright (c) 2019 Niels Gandraß
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ##################################################

TIMEOUT=3600       # Default timeout before considering a drive as idle
POLL_TIME=600      # Default time to wait during a single iostat call
IGNORED_DRIVES="sde"  # Default list of drives that are never spun down
MANUAL_MODE=0      # Default manual mode setting
QUIET=0            # Default quiet mode setting
VERBOSE=0          # Default verbosity level
DRYRUN=0           # Default for dryrun option
declare -A DRIVES  # Associative array for detected drives

##
# Prints the help/usage message
##
function print_usage() {
    cat << EOF
Usage: $0 [-h] [-q] [-v] [-d] [-m] [-t TIMEOUT] [-p POLL_TIME] [-i DRIVE]
Monitors drive I/O and forces HDD spindown after a given idle period.
Resistant to S.M.A.R.T. reads.
A drive is considered as idle and is spun down if there has been no I/O
operations on it for at least TIMEOUT seconds. I/O requests are detected
during intervals with a length of POLL_TIME seconds. Detected reads or
writes reset the drives timer back to TIMEOUT.
Options:
  -q           : Quiet mode. Outputs are suppressed if flag is present.
  -v           : Verbose mode. Prints additonal information during execution.
  -d           : Dry run. No actual spindown is performed.
  -m           : Manual mode. If this flag is set, the automatic drive detection
                 is disabled.
                 This inverts the -i switch which then needs to be used to supply
                 each drive to monitor. All other drives will be ignored.
  -t TIMEOUT   : Number of seconds to wait for I/O in total before considering
                 a drive as idle.
  -p POLL_TIME : Number of seconds to wait for I/O during a single iostat call.
  -i DRIVE     : In automatic drive detection mode (default): Ignores the given
                 drive and never issue a spindown command for it.
                 In manual mode [-m]: Only monitor the specified drives.
                 Multiple drives can be given by repeating the -i switch.
  -h           : Print this help message.
Example usage:
$0
$0 -q -t 3600 -p 600 -i ada0 -i ada1
$0 -q -m -i sda -i sdb -i hda
EOF
}

##
# Writes argument $1 to stdout if $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log() {
    if [[ $QUIET -eq 0 ]]; then
        echo $1
    fi
}

##
# Writes argument $1 to stdout if $VERBOSE is set and $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        if [[ $QUIET -eq 0 ]]; then
            echo $1
        fi
    fi
}

##
# Detects all connected drives and whether they are ATA or SCSI drives.
# Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: This function populates the $DRIVES array directly.
##
function detect_drives() {
    local DRIVE_IDS

    # Detect relevant drives identifiers
    if [[ $MANUAL_MODE -eq 1 ]]; then
        # In manual mode the ignored drives become the explicitly monitored drives
        DRIVE_IDS=" ${IGNORED_DRIVES} "
    else
        DRIVE_IDS=`iostat -x | grep -E '^(hd|sd)' | awk '{printf $1 " "}'`
        DRIVE_IDS=" ${DRIVE_IDS} " # Space padding must be kept for pattern matching

        # Remove ignored drives
        for drive in ${IGNORED_DRIVES[@]}; do
            DRIVE_IDS=`sed "s/ ${drive} / /g" <<< ${DRIVE_IDS}`
        done
    fi
    # Detect protocol type (ATA or SCSI) for each drive and populate $DRIVES array
    for drive in ${DRIVE_IDS}; do
#        if [[ -n $(camcontrol identify $drive |& grep -E "^protocol(.*)ATA") ]]; then
            DRIVES[$drive]="ATA"
#        else
#            DRIVES[$drive]="SCSI"
#        fi
    done
}
##
# Retrieves the list of identifiers (e.g. "ada0") for all monitored drives.
# Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: Must be run after detect_drives().
##
function get_drives() {
    echo "${!DRIVES[@]}"
}
##
# Waits $1 seconds and returns a list of all drives that didn't
# experience I/O operations during that period.
#
# Devices listed in $IGNORED_DRIVES will never get returned.
#
# Arguments:
#   $1 Seconds to listen for I/O before drives are considered idle
##
function get_idle_drives() {
    # Wait for $1 seconds and get active drives
    local ACTIVE_DRIVES=`iostat -zyd $1 1 | tail -n +4 | awk '/sd|hd/{printf $1}{printf " "}'`
    # Remove active drives from list to get idle drives
    local IDLE_DRIVES=" $(get_drives) " # Space padding must be kept for pattern matching
    for drive in ${ACTIVE_DRIVES}; do
        IDLE_DRIVES=`sed "s/ ${drive} / /g" <<< ${IDLE_DRIVES}`
    done
    echo ${IDLE_DRIVES}
}
##
# Determines whether the given drive $1 understands ATA commands
#
# Arguments:
#   $1 Device identifier of the drive
##
function is_ata_drive() {
    if [[ ${DRIVES[$1]} == "ATA" ]]; then echo 1; else echo 0; fi
}
##
# Determines whether the given drive $1 is spinning
#
# Arguments:
#   $1 Device identifier of the drive
##
function drive_is_spinning() {
    if [[ $(is_ata_drive $1) -eq 1 ]]; then
        if [[ -z $(/sbin/hdparm -C /dev/$1 | grep 'active') ]]; then echo 0; else echo 1; fi
    else
        echo "todo: scsi"
    fi
}
##
# Forces the spindown of the drive specified by parameter $1 trough camcontrol
#
# Arguments:
#   $1 Device identifier of the drive
##
function spindown_drive() {
    if [[ $(drive_is_spinning $1) -eq 1 ]]; then
        if [[ $DRYRUN -eq 0 ]]; then
            if [[ $(is_ata_drive $1) -eq 1 ]]; then
                # Spindown ATA drive
                /sbin/hdparm -y /dev/$1
            else
                # Spindown SCSI drive
                echo "todo scsi"
            fi
        fi
        log "$(date '+%F %T') Spun down idle drive: $1"
    else
        log_verbose "$(date '+%F %T') Drive is already spun down: $1"
    fi
}
##
# Generates a list of all active timeouts
##
function get_drive_timeouts() {
    echo -n "$(date '+%F %T') Drive timeouts: "
    for x in "${!DRIVE_TIMEOUTS[@]}"; do printf "[%s]=%s " "$x" "${DRIVE_TIMEOUTS[$x]}" ; done
    echo ""
}
##
# Main program loop
##
function main() {
    if [[ $DRYRUN -eq 1 ]]; then log "Performing a dry run..."; fi
    # Initially identify drives to monitor
    detect_drives
    for drive in ${!DRIVES[@]}; do
        log_verbose "Detected drive ${drive} as ${DRIVES[$drive]} device"
    done
    log "Monitoring drives with a timeout of ${TIMEOUT} seconds: $(get_drives)"
    log "I/O check sample period: ${POLL_TIME} sec"
    # Init timeout counters for all monitored drives
    declare -A DRIVE_TIMEOUTS
    for drive in $(get_drives); do
        DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
    done
    log_verbose "$(get_drive_timeouts)"
    # Drive I/O monitoring loop
    while true; do
        local IDLE_DRIVES=$(get_idle_drives ${POLL_TIME})
        for drive in "${!DRIVE_TIMEOUTS[@]}"; do
            if [[ $IDLE_DRIVES =~ $drive ]]; then
                DRIVE_TIMEOUTS[$drive]=$((DRIVE_TIMEOUTS[$drive] - POLL_TIME))
                if [[ ! ${DRIVE_TIMEOUTS[$drive]} -gt 0 ]]; then
                    DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
                    spindown_drive ${drive}
                fi
            else
                DRIVE_TIMEOUTS[$drive]=${TIMEOUT}
            fi
        done
        log_verbose "$(get_drive_timeouts)"
    done
}
# Parse arguments
while getopts ":hqvdmt:p:i:" opt; do
  case ${opt} in
    t ) TIMEOUT=${OPTARG}
      ;;
    p ) POLL_TIME=${OPTARG}
      ;;
    i ) IGNORED_DRIVES="$IGNORED_DRIVES ${OPTARG}"
      ;;
    q ) QUIET=1
      ;;
    v ) VERBOSE=1
      ;;
    d ) DRYRUN=1
      ;;
    m ) MANUAL_MODE=1
      ;;
    h ) print_usage; exit
      ;;
    : ) print_usage; exit
      ;;
    \? ) print_usage; exit
      ;;
  esac
done
main # Start main program
