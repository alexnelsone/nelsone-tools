#!/bin/bash 
#
#
# description: Init file for file_cleanser script
# chkconfig: 345 99 01
#

# Source function library.
. /etc/init.d/functions


RETVAL=0
DATE=$(date +%Y%m%d)


start() {


        printf "Starting file_cleanser script\n"
        /usr/local/scripts/file_cleanser_start.sh >> /var/log/file_cleanser_start.log-$DATE &
        mkdir -p /var/lock/scripts/
        touch /var/lock/scripts/file_cleanser.lock
        pid=`ps -ef | grep /usr/local/scripts/file_cleanser_start.sh`
        pid=`echo $pid | cut -d " " -f2`
        echo $pid > /var/lock/scripts/file_cleanser.lock
        return $?
}

stop() {
        printf "Stopping move_files_to_s3\n"
        kill -9 `cat /var/lock/scripts/file_cleanser.lock`
        rm -rf /var/lock/scripts/file_cleanser.lock
        return $?
}


case $1 in
        start)
                start
                ;;
        stop)
                stop
                ;;
        status)
                ps -ef |  grep midas
esac
exit $?
