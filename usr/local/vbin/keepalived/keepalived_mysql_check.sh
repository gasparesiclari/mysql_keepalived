#!/bin/bash
# monitor mysql status
virtual_ip=$1
iface=$2
name=$3
report_host=$4
# MySQL Paths and commands
MYSQL_USER="USER"
MYSQL_PASS="PASSWORD"
DATA_DIR="/usr/local/mysql/mysql-$instance/data"
MYSQL="/usr/bin/mysql -s -u${MYSQL_USER} -p${MYSQL_PASS}"
MYSQLADMIN="/usr/bin/mysqladmin -u${MYSQL_USER} -p${MYSQL_PASS}"
R_MYSQL="/usr/bin/mysql -s"
R_MYSQLADMIN="/usr/bin/mysqladmin"
# Other vars
r_user="u_system"
r_psw="metsys_u"
proc_count=`ps ax|grep -w $$|grep -v grep|wc -l`
viface=$iface:$name
virt_iface=`echo $viface|cut -c1-16`
possessed_ip=`/sbin/ifconfig $iface | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'`
possessed_vip=`/sbin/ifconfig $virt_iface | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'`
gateway=`/sbin/ip route|awk '/default/ { print $3 }'`
service_ip=`echo /sbin/ip route|awk '/${iface}/ { print $9 }'`
netmask=`/sbin/ifconfig ${iface}|sed -rn '2s/ .*:(.*)$/\1/p'`
pidfile=/var/log/virtual_ip_take_$virtual_ip.pid
logfile=/var/log/virtual_ip_take_$virtual_ip.log
## FUNCTIONS #########################################################################################################################################################################
function log(){
    echo "#[$$]# `date '+%F %T'` $@" >> $logfile
}
## REPORT SECTION
report_host="NoReport"
## END REPORT SECTION
function notify(){
    STATUS=$1
    /usr/local/vbin/keepalived/keepalived_notif.sh $STATUS $virtual_ip
}
function ping_gw(){
    /bin/ping -q -c 3 -w 10 $gateway >> $logfile 2>&1
    if [ $? == 1 ]
    then
        log "Unreachable GW, IP cannot be taken ... ABORTING"
        pidfile_del
        notify FAULT
        exit 1
    else
        log "GW correctly pinged"
        return 0
    fi
}
function ping_vip(){
    n=$1
    for i in {1..$n}
    do
        /bin/ping -q -c 1 -w 5 $virtual_ip >> $logfile
        if [ $? == 0 ]
        then
            log "Ping $virtual_ip Success! ... ABORTING"
##### THIS CHECKS ARE ALREADY PERFORMED BY NAGIOS
#                       check_mysql_alive
#                       check_slave_status
####
            pidfile_del
            log "### END #####"
            log "### END LOG #####"
            notify FAULT
            exit 1
        else
            log "Ping $virtual_ip: unreachable at try $i ... Go On!"
            stop_replica
        fi
    done
    return 0
}
function pidfile_create(){
    pid=$1
    touch "$pidfile"
    if [ $? == 0 ]
    then
        log "pidfile created"
        echo $$ > $pidfile
        log "pid $pid registered"
        return 0
    else
        log "ERROR ... pidfile cannot be created"
        log "### END #####"
        log "### END LOG #####"
        notify FAULT
        exit 1
    fi
}
function pidfile_del(){
    if [ -e "$pidfile" ]
    then
        rm -f "$pidfile"
        if [ -e "$pidfile" ]
        then
                log "WARNING ... pidfile cannot be removed"
        else
                log "pidfile correctly removed"
        fi
    fi
    return 0
}
function check_pid_file(){
    #log "proc_count = $proc_count"
    if [ -e $pidfile ]
    then
        pid=`head -n 1 $pidfile`
        log "Found previous pidfile with pid $pid ... checking processes"
        proc_check=`ps ax|grep -w "$pid"|grep -v "grep"|wc -l`
        if [ $proc_chec -gt 0 ]
        then
            log "Process $pid is still running ... ABORTING"
            log "##### END #####"
            log "##### END LOG #####"
            notify FAULT
            exit 1
        else
            log "### Old pidfile not removed ... replacing it"
            pidfile_del
            pidfile_create $$
        fi
    else
        pidfile_create $$
    fi
    return 0
}
function instance_start(){
    for i in {1..2}
    do
        /etc/init.d/mysql start
        if [ $? != 0 ]
        then
            log "RESTART FAILED .. ABORTING"
            if [ $i == 2 ]
            then
                log "##### END #####"
                pidfile_del
                log "##### END LOG #####"
                notify FAULT
                exit 1
            fi
        else
            log "instance UP ... OK!"
            return 0
            break
        fi
    done
}
function master_instance_start(){
        instance_start
        if [ $? != 0 ]
        then
                return 1
        else
                return 0
        fi
}
function stop_replica(){
    MASTER_LOG_FILE=`$MYSQL -e 'show slave status\G'|grep "Master_Log_File" | grep -v "Relay_Master_Log_File"|sed -n -r 's/.*Master_Log_File: ([A-Za-z]+)/\1/p'`
    MASTER_LOG_POS=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Read_Master_Log_Pos: ([0-9]+)/\1/p'`
    $MYSQL -e 'stop slave;'
    if [ '$report_host' != 'NoReport' ]
    then
        stop_report_replica
    fi
}
function start_slave(){
        MASTER_LOG_FILE = $1
        MASTER_LOG_POS = $1
        $MYSQL -e "stop slave"
        $MYSQL -e "start slave until master_log_file='$MASTER_LOG_FILE',master_log_pos=$MASTER_LOG_POS"
        if [ $? == 0 ]
        then
            log "SLAVE RUNNING ... OK!"
        else
            log "SLAVE START FAILED ... ABORTING!"
            pidfile_del
            log "##### END LOG #####"
            notify FAULT
            exit 1
        fi
        check_slave_delay $MASTER_LOG_FILE $MASTER_LOG_POS
        return 0
}
function check_replication_errors(){
        IO_ERRNO=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Last_IO_Errno: ([0-9]+)/\1/p'`
        SQL_ERRNO=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Last_SQL_Errno: ([0-9]+)/\1/p'`
        IO_ERR=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Last_IO_Error: ([A-Za-z]+)/\1/p'`
        SQL_ERR=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Last_SQL_Error: ([A-Za-z]+)/\1/p'`
        if [ $SQL_ERRNO -eq 0 ]
        then
            if [ $IO_ERRNO -ne 0 ]
            then
                    log "WARNING - Master instance unreachable: $IO_ERR"
            fi
        else
            log "instance cannot be aligned: SQL Error: [$SQL_ERRNO] - $SQL_ERR ... ABORTING!"
            pidfile_del
            log "##### END LOG #####"
            notify FAULT
            exit 1
        fi
        return 0
}
function check_slave_delay(){
    MASTER_LOG_FILE = $1
    MASTER_LOG_POS = $2
    EXCUTED_MASTER_LOG_FILE=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Relay_Master_Log_File: ([A-Za-z]+)/\1/p'`
    EXEC_MASTER_LOG_POS=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Exec_Master_Log_Pos: ([0-9]+)/\1/p'`
    if [ "$EXCUTED_MASTER_LOG_FILE" != "$MASTER_LOG_FILE" -o "$EXEC_MASTER_LOG_POS" != "$MASTER_LOG_POS" ]
    then
        EXCUTED_MASTER_LOG_FILE=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Relay_Master_Log_File: ([A-Za-z]+)/\1/p'`
        EXEC_MASTER_LOG_POS=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Exec_Master_Log_Pos: ([0-9]+)/\1/p'`
        log "Executed replication $EXCUTED_MASTER_LOG_FILE of $MASTER_LOG_FILE - Executed position $EXEC_MASTER_LOG_POS of $MASTER_LOG_POS"
        check_replication_errors
        log "ERROR: The replica is not aligned!"
        pidfile_del
        notify FAULT
        exit 1
    fi
    log "Replica completely aligned"
    return 0
}
function check_slave_status(){
    MASTER_LOG_FILE = $1
    MASTER_LOG_POS = $2
    ##### Check if I/O Thread and SQL Thread are both up-and-running if MySQL instance is aligned with Master instance
    IO_RUNNING=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Slave_IO_Running: ([A-Za-z]+)/\1/p'|tr '[:upper:]' '[:lower:]'`
    SQL_RUNNING=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Slave_SQL_Running: ([A-Za-z]+)/\1/p'|tr '[:upper:]' '[:lower:]'`
    log "SQL Running: $SQL_RUNNING, I/O Running: $IO_RUNNING"
    if [ "$IO_RUNNING" == "yes" -a "$SQL_RUNNING" == "yes" ]
    then
        log "SLAVE RUNNING"
        $MYSQL -e "stop slave"
        #start_slave $MASTER_LOG_FILE $MASTER_LOG_POS
        check_slave_delay $MASTER_LOG_FILE $MASTER_LOG_POS
    elif [ "$IO_RUNNING" == "no" -a "$SQL_RUNNING" == "no" ]
    then
        log "SLAVE STOPPED ... Attempting slave start"
        start_slave $MASTER_LOG_FILE $MASTER_LOG_POS
        check_slave_delay $MASTER_LOG_FILE $MASTER_LOG_POS
    elif [ "$IO_RUNNING" != "$SQL_RUNNING" ]
    then
        log "WARNING - Threads can be uncorrectly initialized: I/O Tread: $IO_RUNNING - SQL Tread: $SQL_RUNNING"
        $MYSQL -e "stop slave"
        start_slave $MASTER_LOG_FILE $MASTER_LOG_POS
        check_slave_delay $MASTER_LOG_FILE $MASTER_LOG_POS
    fi
}
function check_mysql_alive(){
    $MYSQLADMIN ping > /dev/null 2>&1
    if [ $? != 0 ]
    then
            log "instance IS DOWN!"
            ## check if the flag file is older than 8 hours ( 28800 sec )
            ## if it is older, than we will remove it and start mysql
            ## if it is younger, we will exit and check on the next loop
            file_age=`echo $(( `date +%s` - `stat -L --format %Y /tmp/mysql.stop` ))`
            if [ $file_age -gt 28800 ]
            then
                log "The flag file ( /tmp/mysql.stop ) has been created $file_age second ago, so it is is older than 8 hours."
                log "Starting the MySQL instance."
                instance_start
            else
                log "The backup file has been created $file_age second ago, so it is is younger than 8 hours."
                log "Exiting waiting the next loop."
                pidfile_del
                notify FAULT
                exit 1
            fi
    else
        log "instance UP ... OK!"
    fi
}
function refresh_and_save_mysql_info(){
    ## enable log_slave_update
    #log_slave_update=`$MYSQL -B -N -e "select VARIABLE_VALUE from information_schema.GLOBAL_VARIABLES where VARIABLE_NAME = 'log_slave_updates'"`
    #if [ "$log_slave_update" == "OFF" ]
    #then
        #enable log_slave_update
    #    sed -i.`date +%Y%m%d_%H%M%S` -e 's/#.*log_slave_updates/log_slave_updates/g' /etc/mysql-$instance.cnf
    #fi
    ## create a new replication_log file
    log "Restarting the MySQL instance."
    $MYSQLADMIN shutdown
    instance_start
    if [ "$report_host" != "NoReport" ]
    then
        source report_replication_check.sh $report_host save_mysql_info
    fi
}
######################################################################################################################################################################################
log "##### STARTING LOG #####"
if [ "$possessed_vip" == "$virtual_ip" ]
then
    log "Server owns VIP $virtual_ip"
    log "$MYSQLADMIN"
    $MYSQLADMIN ping > /dev/null 2>&1
    if [ $? != 0 ]
    then
        check_pid_file
        log "instance DOWN! ... Trying to restart instance"
        master_instance_start
        log "##### END #####"
        pidfile_del
        log "]##### END LOG #####"
    else
        log "instance Up"
        log "##### END LOG #####"
        exit 0
    fi
    if [ "$report_host" != "NoReport" ]
    then
        REPORT_MASTER_LOG_POS=`$R_MYSQL -h $report_host -u $r_user -p$r_psw -e 'show slave status\G'|sed -n -r 's/.*Read_Master_Log_Pos: ([0-9]+)/\1/p'`
        REPORT_MASTER_LOG_FILE=`$R_MYSQL -h $report_host -u $r_user -p$r_psw -e 'show slave status\G'|grep "Master_Log_File" | grep -v "Relay_Master_Log_File"|sed -n -r 's/.*Master_Log_File: ([A-Za-z]+)/\1/p'`
        check_report_slave_delay $REPORT_MASTER_LOG_FILE $REPORT_MASTER_LOG_POS
    fi
else
    log "Server is Fail-Over"
    log "$MYSQLADMIN"
    check_pid_file
    ping_gw
    check_mysql_alive
    ping_vip 1
    MASTER_HOST=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Master_Host: ([A-Za-z]+)/\1/p'`
    MASTER_PORT=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Master_Port: ([0-9]+)/\1/p'`
    MASTER_LOG_POS=`$MYSQL -e 'show slave status\G'|sed -n -r 's/.*Read_Master_Log_Pos: ([0-9]+)/\1/p'`
    MASTER_LOG_FILE=`$MYSQL -e 'show slave status\G'|grep "Master_Log_File" | grep -v "Relay_Master_Log_File"|sed -n -r 's/.*Master_Log_File: ([A-Za-z]+)/\1/p'`
    MY_HOST=`hostname`
    MY_PORT=`$MYSQL -e 'show variables like "port"\G'|sed -n -r 's/.*Value: ([0-9]+)/\1/p'`
    MY_LOG_FILE=`$MYSQL -e 'show master status\G'|sed -n -r 's/.*File: ([A-Za-z]+)/\1/p'`
    MY_LOG_POS=`$MYSQL -e 'show master status\G'|sed -n -r 's/.*Position: ([0-9]+)/\1/p'`
    check_slave_status $MASTER_LOG_FILE $MASTER_LOG_POS
    if [ "$report_host" != "NoReport" ]
    then
        report_replication_table $MY_HOST $MY_PORT $MY_LOG_FILE $MY_LOG_POS 'no' 0
    fi
    ## refresh binary_logs and save master info
    refresh_and_save_mysql_info
    if [ ${#viface} -gt 16 ]
    then
            log "WARNING - Virtual Interface name too long, a maximum of 16 chars can be used, the name will be truncated to $virt_iface"
    fi
    log "OK, If needed this instance can take the IP."
    pidfile_del
    log "##### END LOG #####"
    exit 0
fi
