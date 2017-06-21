#!/bin/sh

# Common tuning functions that are useful to both SAP Netweaver and HANA.

. /usr/lib/tuned/functions

# Invoke bc arbitrary precision calculator.
math() {
  echo $* | bc | tr -d '\n'
}

# Invoke bc arbitrary precision calculator to do a comparison. Return "1" if comparison is truthy.
math_test() {
  [ $(echo $* | bc | tr -d '\n') = '1' ] && echo -n 1
}

# If a tuning parameter is set in the [sysctl] section of tuned.conf file
# do not overwrite it.
respect_tuned_file() {
   grep $1 $2 2>&1 > /dev/null
   if [ "$?" -ne 0 ]; then
      echo no
   else
      echo yes
   fi
}

# write information to the log file of tuned or to the system log
# and additional write it to stderr
# write to stderr seems not to work with tuned-adm
write_log() {
   log_date=`date '+%F %T'`
   script_name=`caller | awk '{print $2}'`
   if [ -z "$log_file" ]; then
        logger -s "$1 sapconf: $2"
   else
        case $1 in
        INFO)
                echo "$log_date     $1      $script_name: $2" >> $log_file
                ;;
        *)
                echo "$log_date     $1 $script_name: $2" >> $log_file
                ;;
        esac
        echo "$1: $2" >&2
        echo > /dev/tty1
        echo "$1 sapconf: $2" > /dev/tty1
   fi
}

# Tune system according to 1275776 - Preparing SLES for SAP and 1984787 - Installation notes.
tune_preparation() {
    log_file=""
    [ -f /var/log/tuned/tuned.log ] && log_file=/var/log/tuned/tuned.log
    cfg_file = `caller | sed 's#script.sh#tuned.conf#'`
    cfg_file = ${cfg_file#*[[:space:]]}
    # Read total memory size (including swap) in KBytes
    declare -r VSZ=$(awk -v t=0 '/^(Mem|Swap)Total:/ {t+=$2} END {print t}' < /proc/meminfo)
    declare -r PSZ=$(getconf PAGESIZE)

    # These names are the tuning parameters
    declare -r TUNED_VARS="TMPFS_SIZE SHMALL SEMMSL SEMMNS SEMOPM SEMMNI SHMMAX MAX_MAP_COUNT"
    for name in $TUNED_VARS; do
        # Current value
        declare $name=0
        # Calculated recommended value / future value
        declare ${name}_REQ=0
        # Minimum boundary is set set in sysconfig/sapconf
        declare ${name}_MIN=0
    done

    # Read current kernel tuning values from sysctl
    declare SHMMAX=$(sysctl -n kernel.shmmax)
    declare SHMALL=$(sysctl -n kernel.shmall)
    declare MAX_MAP_COUNT=$(sysctl -n vm.max_map_count)
    read -r SEMMSL SEMMNS SEMOPM SEMMNI < <(sysctl -n kernel.sem)

    # Read current tmpfs mount options and size
    read discard discard discard TMPFS_OPTS discard < <(grep -E '^tmpfs /dev/shm .+' /proc/mounts)
    if [ ! "$TMPFS_OPTS" ]; then
        echo "The system does not use tmpfs. Please configure tmpfs and try again." 1>&2
        exit 1
    fi
    # Remove size= from mount options
    TMPFS_OPTS=$(echo "$TMPFS_OPTS" | sed 's/size=[^,]\+//' | sed 's/^,//' | sed 's/,$//' | sed 's/,,/,/')
    declare TMPFS_SIZE=$(($(stat -fc '(%b*%S)>>10' /dev/shm))) # in KBytes

    # Read minimal value requirements from sysconfig
    if [ -r /etc/sysconfig/sapconf ]; then
        source /etc/sysconfig/sapconf
    else
        echo 'Failed to read /etc/sysconfig/sapconf' >&2
        exit 1
    fi

    # Calculate tuning parameter recommendations according to SAP notes
    declare SHMALL_REQ=$( math "$VSZ*1024/$PSZ" )
    declare SHMMAX_REQ=$( math "$VSZ*1024" )
    declare TMPFS_SIZE_REQ=$( math "$VSZ*$VSZ_TMPFS_PERCENT/100" )

    # No value may drop below manually defined minimal or the current value
    # TODO: Think about why the minimal value is needed, saptune does not use them anymore.
    for name in $TUNED_VARS; do
        min=${name}_MIN
        req=${name}_REQ
        val=${!name}
        if [ ! "${!req}" -o $( math_test "${!req} < $val" ) ]; then
            declare $req="$val"
        fi
        if [ $( math_test "${!req} < ${!min}" ) ]; then
            declare $req="${!min}"
        fi
    done

    # Tune tmpfs - enlarge if necessary
    if [ $( math_test "$TMPFS_SIZE_REQ > $TMPFS_SIZE" ) ]; then
        save_value tmpfs.size "$TMPFS_SIZE"
        save_value tmpfs.mount_opts "$TMPFS_OPTS"
        mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE_REQ}k" /dev/shm
    fi

    # Tune kernel parameters
    if [ "respect_tuned_file kernel.shmmax $cfg_file" == "no" ]; then
        save_value kernel.shmmax "$SHMMAX"
        sysctl -w kernel.shmmax="$SHMMAX_REQ"
    fi
    if [ "respect_tuned_file kernel.sem $cfg_file" == "no" ]; then
        save_value kernel.sem "$(sysctl -n kernel.sem)"
        sysctl -w kernel.sem="$SEMMSL_REQ $SEMMNS_REQ $SEMOPM_REQ $SEMMNI_REQ"
    fi
    if [ "respect_tuned_file kernel.shmall $cfg_file" == "no" ]; then
        save_value kernel.shmall "$SHMALL"
        sysctl -w kernel.shmall="$SHMALL_REQ"
    fi
    if [ "respect_tuned_file vm.max_map_count $cfg_file" == "no" ]; then
        save_value vm.max_map_count "$MAX_MAP_COUNT"
        sysctl -w vm.max_map_count="$MAX_MAP_COUNT_REQ"
    fi

    # Tune ulimits for the max number of open files (rollback is not necessary in revert function)
    all_nofile_limits=""
    for limit in ${!LIMIT_*}; do # LIMIT_ parameters originate from sysconf/sapconf
        all_nofile_limits="$all_nofile_limits\n${!limit}"
    done
    for ulimit_group in @sapsys @sdba @dba; do
        for ulimit_type in soft hard; do
            sysconf_line=$(echo -e "$all_nofile_limits" | grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+")
            limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+" /etc/security/limits.conf)
            if [ "$limits_line" ]; then
                sed -i "/$limits_line/d" /etc/security/limits.conf
            fi
            echo "$sysconf_line" >> /etc/security/limits.conf
        done
    done

   # Amend logind's behaviour (bsc#1031355, bsc#1039309, bsc#1043844)
   # NO revert to avoid rebooting the system every time.
   write_log INFO "Set the maximum number of OS tasks each user may run concurrently (UserTasksMax) to 'infinity'" 
   //logger -s "INFO: Set the maximum number of OS tasks each user may run concurrently (UserTasksMax) to 'infinity'"
   change_sap_conf=false
   LOGIND_DIR=/etc/systemd/logind.conf.d
   SAP_LOGIN_FILE=$LOGIND_DIR/sap.conf
   [ ! -d $LOGIND_DIR ] && mkdir -p $LOGIND_DIR
   if [ -f $SAP_LOGIN_FILE ]; then
        grep "^[[:blank:]]*UserTasksMax[[:blank:]]*=[[:blank:]]*infinity" $SAP_LOGIN_FILE > /dev/null 2>&1
        if [ "$?" -ne 0 ]; then
                mv $SAP_LOGIN_FILE ${SAP_LOGIN_FILE}.sav
                change_sap_conf=true
        else
                write_log ATTENTION "With this setting your system is vulnerable to fork bomb attacks."
        fi
   else
        change_sap_conf=true
   fi
   if $change_sap_conf; then
        echo "[Login]" > $SAP_LOGIN_FILE
        echo "UserTasksMax=infinity" >> $SAP_LOGIN_FILE 
        write_log ATTENTION "Please reboot the system for the changes to take effect"
   fi
}

# Revert tuning operations conducted by 1275776 - Preparing SLES for SAP and 1984787 - Installation notes.
revert_preparation() {
    # Restore tuned kernel parameters
    SHMMAX=$(restore_value kernel.shmmax)
    SEM=$(restore_value kernel.sem)
    SHMALL=$(restore_value kernel.shmall)
    MAX_MAP_COUNT=$(restore_value vm.max_map_count)
    [ "$SHMMAX" ] && sysctl -w kernel.shmmax="$SHMMAX"
    [ "$SHMALL" ] && sysctl -w kernel.shmall="$SHMALL"
    [ "$SEM" ] && sysctl -w kernel.sem="$SEM"
    [ "$MAX_MAP_COUNT" ] && sysctl -w vm.max_map_count="$MAX_MAP_COUNT"

    # Restore the size of tmpfs
    TMPFS_SIZE=$(restore_value tmpfs.size)
    TMPFS_OPTS=$(restore_value tmpfs.mount_opts)
    [ "$TMPFS_SIZE" -a -e /dev/shm ] && mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE}k" /dev/shm
}
