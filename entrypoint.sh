#!/bin/bash

# Crontab configuration
if [ -n "$DCU_CRONTAB_EXECUTION_EXPRESSION" ]; then
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Configuring cronjob..."
    echo "$DCU_CRONTAB_EXECUTION_EXPRESSION /opt/dcu/dcu.sh" > /etc/crontabs/root
fi

# Postfix configuration
if [[ "$(postconf -h relayhost)" != "$DCU_MAIL_RELAYHOST" ]]; then
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Configuring postfix relayhost to "$DCU_MAIL_RELAYHOST"..."
    postconf -e "relayhost = $DCU_MAIL_RELAYHOST"
    
    if pgrep "postfix" > /dev/null; then
        echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Restarting postfix..."
        postfix stop
        postfix start
    fi
else
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Postfix relayhost is already configured to $DCU_MAIL_RELAYHOST"
fi

if ! pgrep "postfix" > /dev/null; then
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Starting postfix..."
    postfix start
fi

# Command line interpreting
if [ -z "$1" ]; then
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Starting crond in foreground..."
    crond -f
elif [ "$1" = "--run" ]; then
    if [ "$2" = "--force" ] || [ "$2" = "-f" ]; then
        echo "INFO   Removing PID file \"/opt/dcu/dcu.sh.pid\"..."
        rm -f /opt/dcu/dcu.sh.pid 2>/dev/null
    fi
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Executing \"/opt/dcu/dcu.sh\"..."
    /opt/dcu/dcu.sh
elif [ "$1" = "--self-update" ] || { [ "$1" = "dcu" ] && [ "$2" = "--self-update" ]; }; then
    echo "INFO   Waiting for status update..."
    start_time=$(date +%s)
    while [[ ! -f "/opt/dcu/.main_update_process_completed" ]]; do
        now_time=$(date +%s)
        if (( now_time - start_time >= 3600 )); then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] ERROR  Timeout reached!"
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Exiting..."
            sleep 10
            exit 1
        fi
        sleep 10
    done
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO   Proceeding with self-update process..."
    echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO       Executing \"/opt/dcu/dcu.sh\"..."
    /opt/dcu/dcu.sh
fi