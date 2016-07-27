#!/bin/bash
# monitor mysql status
STATE=$1
virtual_ip=$2
logfile=/var/log/keepalived_status.log
## FUNCTIONS #########################################################################################################################################################################
function log(){
    echo "`date "+%F %T"` $@" >> $logfile
}
log "# $virtual_ip : $STATE"
