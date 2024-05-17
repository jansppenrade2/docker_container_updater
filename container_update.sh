#!/bin/bash
#
# DOCKER CONTAINER UPDATER
# Automatic Docker Container Updater Script
#
# ## Version
# 2024.05.16-1
#
# ## Changelog
# 2024.05.16-1, janseppenrade2: Completely redesigned for enhanced performance and a better overview and more reliability - Crafted with lots of love and a touch of magic

configFile="/usr/local/etc/container_update/container_update.ini"
pidFile="$(dirname "$(readlink -f "$0")")/`basename "$0"`.pid"
start_time=$(date +%s)
stats_execution_time=0
stats_errors_count=0
stats_warnings_count=0
mail_report_available=false
mail_report_actions_taken=""
mail_report_available_updates=""
mail_report_removed_container_backups=""

Acquire-Lock() {
    local pidFile_creation_time=""
    local pidFile_age=""
    local current_time=""
    local script_timeout=10800 # 3 hours
    local test_mode=$(Read-INI "$configFile" "general" "test_mode")

    [ "$test_mode" == false ] && sleep $((RANDOM % 5))
    if test -f "$pidFile"; then
        pidFile_creation_time=$(stat -c %Y "$pidFile")
        current_time=$(date +%s)
        pidFile_age=$((current_time - pidFile_creation_time))
        if (( pidFile_age > $script_timeout )); then
            echo "The PID file is older than $script_timeout seconds. Forcing lock acquiration..."
            rm -f "$pidFile" || { Write-Log "ERROR" "Failed to remove \"$pidFile\""; End-Script 1; }
        else
            remaining=$((script_timeout - pidFile_age))
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] WARNING The PID file was created less than $script_timeout seconds ago"
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] INFO    Able to force acquisition in $remaining seconds"
            exit 0
        fi
    fi
    echo $$ > "$pidFile" || { echo "[$(date +%Y/%m/%d\ %H:%M:%S)] ERROR   Failed to create \"$pidFile\""; exit 1; }
    start_time=$(date +%s)
}

End-Script() {
    local exitcode=${1:-0}

    if [ -z "$exitcode" ]; then
        exitcode=0
    fi

    Prune-Log $(Read-INI "$configFile" "log" "retention")

    Write-Log "INFO" "Removing PID file (\"$pidFile\")"
    rm -f "$pidFile" 2>/dev/null || Write-Log "ERROR" "Failed to remove PID file (\"$pidFile\")"

    local end_time=$(date +%s)
    stats_execution_time=$((end_time - start_time))

    if [ $exitcode -gt 0 ]; then
        Write-Log "ERROR" "Exiting with code $exitcode after an execution time of $stats_execution_time second(s) with $stats_warnings_count warning(s) and $stats_errors_count error(s)"
    else
        Write-Log "INFO" "Script execution has been ended properly after $stats_execution_time second(s) with $stats_warnings_count warning(s) and $stats_errors_count error(s)"
    fi

    exit $exitcode
}

Read-INI() {
    local filePath="$1"
    local section="$2"
    local key="$3"
    local in_section=false

    if ! grep -q "^\[$section\]" "$filePath" 2>/dev/null; then
        return
    fi
    
    while IFS= read -r line; do
        if [[ "$line" == "[${section}]" ]]; then
            in_section=true
        elif [[ "$line" == "["* ]]; then
            in_section=false
        fi

        if $in_section; then
            if [[ "$line" == "${key} ="* || "$line" == "${key}="* ]]; then
                echo "$(echo $line | sed 's/^[^=]*= *//')"
                break
            fi
        fi
    done < "$filePath"
}

Write-INI() {
    local filePath="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local in_section=false
    local line_number=1
    local found_key_in_section=false

    if ! grep -q "^\[$section\]" "$filePath"; then
        if [ ! -s "$filePath" ]; then
            echo "[$section]" >> "$filePath"
        else
            echo "" >> "$filePath"
            echo "[$section]" >> "$filePath"
        fi
    fi
    
    while IFS= read -r line; do
        if [[ "$line" == "[${section}]" ]]; then
            in_section=true
        elif [[ "$line" == "["* ]]; then
            in_section=false
        fi

        if $in_section; then
            if [[ "$line" == "${key} ="* || "$line" == "${key}="* ]]; then
                found_key_in_section=true
                sed -i "${line_number}s#.*#$key=$value#" "$filePath"
                break
            fi
        fi
        ((line_number++))
    done < "$filePath"

    if [ "$found_key_in_section" = false ]; then
        line_number=1
        while IFS= read -r line; do
            if [[ "$line" == "[${section}]" ]]; then
                sed -i "${line_number}a\\$key=$value" "$filePath"
                break
            fi
            ((line_number++))
        done < "$filePath"
    fi
}

Write-Log () {
    local level=$1
    local message=$2
    local logLevel=$(Read-INI "$configFile" "log" "level" | tr '[:lower:]' '[:upper:]')
    local test_mode=$(Read-INI "$configFile" "general" "test_mode")
    local logFile=$(Read-INI "$configFile" "log" "filePath")
    local cmd_tput=$(Read-INI "$configFile" "paths" "tput")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local logFileFolder=$(dirname "$logFile")

    if [ -z "$logLevel" ] && test -f "$configFile"; then
        if [ -n "$logFile" ] && test -f "$logFile"; then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] WARNING No log level configured. Using default of \"DEBUG\"" | tee -a "$logFile"
        else
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] WARNING No log level configured. Using default of \"DEBUG\""
        fi
        ((stats_warnings_count++))
        logLevel="DEBUG"
    fi

    if [ -n "$logFileFolder" ] && [ -n "$logFile" ]; then
        mkdir -p $logFileFolder 2>/dev/null || End-Script 1
        touch $logFile 2>/dev/null || End-Script 1
    fi

    if [ "$logLevel" != "DEBUG" ] && [ "$logLevel" != "INFO" ] && [ "$logLevel" != "WARNING" ] && [ "$logLevel" != "ERROR" ]; then
        logLevel="DEBUG"
    fi

    if [[ "$message" == *"<print_line>"* ]] && [ -n "$cmd_tput" ]; then
        local leading_spaces=$(expr match "$message" ' *')
        local cols=$(( $($cmd_tput cols) - ( 35 + $leading_spaces ) ))
        local line_prefix=$(printf "%-${leading_spaces}s" " ")
        local line=$(printf "%0.s-" $(seq 1 $cols))
        message="$line_prefix$line"
    elif [[ "$message" == *"<print_line>"* ]] && [ -z "$cmd_tput" ]; then
        local line="---------------------------------------------------------------------------------------------------------------------------"
        message=$(echo "$message" | $cmd_sed "s/<print_line>/$line/g")
    fi

    if [ "$level" = "DEBUG" ] && { [ "$logLevel" = "DEBUG" ]; }; then
        if [ -n "$logFile" ] && test -f "$logFile"; then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level   $message" | tee -a "$logFile"
        else
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level   $message"
        fi
    elif [ "$level" = "INFO" ] && { [ "$logLevel" = "DEBUG" ] || [ "$logLevel" = "INFO" ]; }; then
        if [ -n "$logFile" ] && test -f "$logFile"; then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level    $message" | tee -a "$logFile"
        else
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level    $message"
        fi
    elif [ "$level" = "WARNING" ] && { [ "$logLevel" = "DEBUG" ] || [ "$logLevel" = "INFO" ] || [ "$logLevel" = "WARNING" ]; }; then
        if [ -n "$logFile" ] && test -f "$logFile"; then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level $message" | tee -a "$logFile"
        else
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level $message"
        fi
        ((stats_warnings_count++))
    elif [ "$level" = "ERROR" ] && { [ "$logLevel" = "DEBUG" ] || [ "$logLevel" = "INFO" ] || [ "$logLevel" = "WARNING" ] || [ "$logLevel" = "ERROR" ]; }; then
        if [ -n "$logFile" ] && test -f "$logFile"; then
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level   $message" | tee -a "$logFile"
        else
            echo "[$(date +%Y/%m/%d\ %H:%M:%S)] $level   $message"
        fi
        ((stats_errors_count++))
    fi
}

Prune-Log() {
    local retention=${1:-7}
    local logFile=$(Read-INI "$configFile" "log" "filePath")
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")

    if [ -n "$logFile" ] && test -f "$logFile"; then
        local current_time=$(date +%s)
        local timestamp=$(echo "$(head -n 1 "$logFile")" | $cmd_awk -F'[][]' '{print $2}')
        local timestamp_seconds=$(date -d "$timestamp" +%s)
        local difference=$(( (current_time - timestamp_seconds) / 86400 ))
        #local difference=$($cmd_awk 'BEGIN{ printf "%.0f", (current_time - timestamp_seconds) / 86400 }') # rounded up
        
        if [ "$difference" -gt "$retention" ]; then
            Write-Log "INFO" "Pruning log file (Keeping entries of the last $retention day(s))..."
            while IFS= read -r line; do
                timestamp=$(echo "$line" | $cmd_awk -F'[][]' '{print $2}')
                timestamp_seconds=$(date -d "$timestamp" +%s)
                difference=$(( (current_time - timestamp_seconds) / 86400 ))
                if (( $difference < $retention )); then
                    echo $line >> "$logFile.truncated"
                fi
            done < "$logFile"   
            mv -f "$logFile.truncated" "$logFile"
            Write-Log "INFO"  "Pruning log file has been completed"
        else
            Write-Log "DEBUG" "Pruning log file skipped"
        fi
    fi
}

Get-Path() {
    local name=$1

    if [ -x "/opt/bin/$name" ]; then
        echo "/opt/bin/$name"
        return
    fi

    if [ -x "/opt/sbin/$name" ]; then
        echo "/opt/sbin/$name"
        return
    fi

    local which_path=$(which $name 2>/dev/null | grep -v '^alias' 2>/dev/null)
    if [ -n "$which_path" ]; then
        echo "$which_path"
        return
    fi

    local whereis_path=$(whereis -b $name 2>/dev/null | gawk '{print $2}' 2>/dev/null)
    if [ -n "$whereis_path" ]; then
        echo "$whereis_path"
        return
    fi
}

Validate-ConfigFile() {
    local configFileFolder=$(dirname "$configFile")
    local validationError=false
    local rule_default_exists=false

    if ! test -f "$configFile"; then
        Write-Log "INFO" "No configuration file found in \"$configFile\""
        Write-Log "INFO" "Generating new configuration file..."

        mkdir -p $configFileFolder 2>/dev/null || { Write-Log "ERROR" "Failed to create \"$configFileFolder\""; End-Script 1; }
        touch $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to create \"$configFile\""; End-Script 1; }
        chmod ugo+rw $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to modify permissons on \"$configFile\""; End-Script 1; }

        echo "[general]" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "test_mode=true" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "prune_images=true" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "prune_container_backups=true" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "container_backups_retention=7" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "container_backups_keep_last=1" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "container_update_validation_time=120" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "update_rules=*[0.1.1-1,true]" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "docker_hub_api_url=https://registry.hub.docker.com/v2" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "docker_hub_api_image_tags_page_size_limit=100" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "docker_hub_api_image_tags_page_crawl_limit=10" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "pre_scripts_folder=/usr/local/etc/container_update/pre-scripts" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "post_scripts_folder=/usr/local/etc/container_update/post-scripts" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "[paths]" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "tput=$(Get-Path tput)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "gawk=$(Get-Path gawk)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "cut=$(Get-Path cut)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "docker=$(Get-Path docker)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "grep=$(Get-Path grep)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "jq=$(Get-Path jq)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "sed=$(Get-Path sed)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "wget=$(Get-Path wget)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "sort=$(Get-Path sort)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "sendmail=$(Get-Path sendmail)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "[log]" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "filePath=/var/log/container_update.log" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "level=DEBUG" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "retention=7" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "[mail]" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "notifications_enabled=false" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "mode=sendmail" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "from=" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "recipients=" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
        echo "subject=Docker Container Update Report from $(hostname)" >> $configFile 2>/dev/null || { Write-Log "ERROR" "Failed to add value to \"$configFile\""; End-Script 1; }
    else
        Write-Log "INFO" "Existing configuration file found in \"$configFile\""
    fi

    Write-Log "INFO" "Validating configuration file..."
    if [ $(Read-INI "$configFile" "general" "test_mode") != true ] && [ $(Read-INI "$configFile" "general" "test_mode") != false ]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] test_mode\" (Expected: \"true\" or \"false\")"
        validationError=true
    fi
    if [ $(Read-INI "$configFile" "general" "prune_images") != true ] && [ $(Read-INI "$configFile" "general" "prune_images") != false ]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] prune_images\" (Expected: \"true\" or \"false\")"
        validationError=true
    fi
    if [ $(Read-INI "$configFile" "general" "prune_container_backups") != true ] && [[ $(Read-INI "$configFile" "general" "prune_container_backups") != false ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] prune_container_backups\" (Expected: \"true\" or \"false\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "container_backups_retention") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] container_backups_retention\" (Expected: Type of \"integer\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "container_backups_keep_last") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] container_backups_keep_last\" (Expected: Type of \"integer\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "container_update_validation_time") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] container_update_validation_time\" (Expected: Type of \"integer\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "pre_scripts_folder") =~ ^/.* ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] pre_scripts_folder\" (Expected: Type of \"path\")"
    fi
    if ! [[ $(Read-INI "$configFile" "general" "post_scripts_folder") =~ ^/.* ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] post_scripts_folder\" (Expected: Type of \"path\")"
    fi

    IFS=' ' read -ra update_rules <<< "$(Read-INI "$configFile" "general" "update_rules")"
    if [ ${#update_rules[@]} -eq 0 ]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] update_rules\" (Expected: At least one rule)"
        validationError=true
    else
        local rule_regex='^(\*|[a-zA-Z_][a-zA-Z0-9_-]*)\[([0-9]+(&\(([Mmpb][><=][0-9]+[&|]?)+\))?[.]){2}([0-9]+(&\(([Mmpb][><=][0-9]+[&|]?)+\))?[-]){1}([0-9]+(&\(([Mmpb][><=][0-9]+[&|]?)+\))?[,]){1}(true|false)\]$'
        for update_rule in "${update_rules[@]}"; do
            if ! [[ "$update_rule" =~ $rule_regex ]]; then
                Write-Log "ERROR" "    => Invalid value in \"[general] update_rules\": Syntax validation error for the rule \"$update_rule\""
                validationError=true
            else
                Write-Log "DEBUG" "    => \"[general] update_rules\": The rule \"$update_rule\" matches the regex pattern for the rule syntax validation"
            fi

            if [[ "${update_rule:0:1}" == "*" ]]; then
                Write-Log "DEBUG" "    => \"[general] update_rules\": Found default rule \"$update_rule\""
                rule_default_exists=true
            fi
        done
    fi

    local url_regex='^(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]\.[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]$'
    if ! [[ "$(Read-INI "$configFile" "general" "docker_hub_api_url")" =~ $url_regex ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] docker_hub_api_url\": \"$(Read-INI "$configFile" "general" "docker_hub_api_url")\" (Expected: Type of \"URL\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_size_limit") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] docker_hub_api_image_tags_page_size_limit\" (Expected: Type of \"integer\")"
        validationError=true
    elif (( $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_size_limit") <= 0 || $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_size_limit") > 100 )); then
        Write-Log "ERROR" "    => Invalid value for \"[general] docker_hub_api_image_tags_page_size_limit\" (Min.: 1, Max.: 100, Current: $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_size_limit"))"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_crawl_limit") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[general] docker_hub_api_image_tags_page_crawl_limit\" (Expected: Type of \"integer\")"
        validationError=true
    elif (( $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_crawl_limit") <= 0 )); then
        Write-Log "ERROR" "    => Invalid value for \"[general] docker_hub_api_image_tags_page_crawl_limit\" (Min.: 1, Current: $(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_crawl_limit"))"
        validationError=true
    fi

    if ! [[ $(Read-INI "$configFile" "paths" "tput") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "tput" "$(Get-Path tput)"
        if ! [[ $(Read-INI "$configFile" "paths" "tput") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] tput\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "gawk") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "gawk" "$(Get-Path gawk)"
        if ! [[ $(Read-INI "$configFile" "paths" "gawk") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] gawk\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "cut") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "cut" "$(Get-Path cut)"
        if ! [[ $(Read-INI "$configFile" "paths" "cut") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] cut\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "docker") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "docker" "$(Get-Path docker)"
        if ! [[ $(Read-INI "$configFile" "paths" "docker") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] docker\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "grep") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "grep" "$(Get-Path grep)"
        if ! [[ $(Read-INI "$configFile" "paths" "grep") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] grep\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "jq") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "jq" "$(Get-Path jq)"
        if ! [[ $(Read-INI "$configFile" "paths" "jq") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] jq\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "sed") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "sed" "$(Get-Path sed)"
        if ! [[ $(Read-INI "$configFile" "paths" "sed") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] sed\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "wget") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "wget" "$(Get-Path wget)"
        if ! [[ $(Read-INI "$configFile" "paths" "wget") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] wget\" (Expected: Type of \"path\")"
        fi
    fi
    if ! [[ $(Read-INI "$configFile" "paths" "sort") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "sort" "$(Get-Path sort)"
        if ! [[ $(Read-INI "$configFile" "paths" "sort") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] sort\" (Expected: Type of \"path\")"
        fi
    fi
    if [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" ] && ! [[ $(Read-INI "$configFile" "paths" "sendmail") =~ ^/.* ]]; then
        Write-INI "$configFile" "paths" "sendmail" "$(Get-Path sendmail)"
        if [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" ] && ! [[ $(Read-INI "$configFile" "paths" "sendmail") =~ ^/.* ]]; then
            Write-Log "WARNING" "    => Invalid value for \"[paths] sendmail\" (Expected: Type of \"path\")"
        fi
    fi

    if ! [[ $(Read-INI "$configFile" "log" "filePath") =~ ^/.* ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[log] filePath\" (Expected: Type of \"path\")"
        validationError=true
    fi
    if [ $(Read-INI "$configFile" "log" "level") != "DEBUG" ] && [ $(Read-INI "$configFile" "log" "level") != "INFO" ] && [ $(Read-INI "$configFile" "log" "level") != "WARNING" ] && [ $(Read-INI "$configFile" "log" "level") != "ERROR" ]; then
        Write-Log "ERROR" "    => Invalid value for \"[log] level\" (Expected: \"DEBUG\", \"INFO\", \"WARNING\", or \"ERROR\")"
        validationError=true
    fi
    if ! [[ $(Read-INI "$configFile" "log" "retention") =~ ^[0-9]+$ ]]; then
        Write-Log "ERROR" "    => Invalid value for \"[log] retention\" (Expected: Type of \"integer\")"
        validationError=true
    fi

    if [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" != "true" ] && [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" != "false" ]; then
        Write-Log "ERROR" "    => Invalid value for \"[mail] notifications_enabled\" (Expected: \"true\" or \"false\")"
        validationError=true
    fi
    if [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" ] && [ "$(Read-INI "$configFile" "mail" "mode")" != "sendmail" ]; then
        Write-Log "ERROR" "    => Invalid value for \"[mail] mode\" (Expected: \"sendmail\")"
        validationError=true
    fi
    if [[ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" && ! $(Read-INI "$configFile" "mail" "from") =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        Write-Log "WARNING" "    => Invalid value for \"[mail] from\" (Expected: Type of \"email\")"
    fi
    if [[ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" && ! $(Read-INI "$configFile" "mail" "recipients") =~ ^([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})([[:space:]]*[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})*$ ]]; then
        Write-Log "WARNING" "    => Invalid value for \"[mail] recipients\" (Expected: One or multiple E-Mail addresses seperated by spaces)"
    fi
    if [[ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" && -z $(Read-INI "$configFile" "mail" "subject") ]]; then
        Write-Log "WARNING" "    => Empty value for \"[mail] subject\""
    fi

    if [ $rule_default_exists == false ]; then
        Write-Log "ERROR" "    => Invalid value in \"[general] update_rules\": The default rule is mandatory"
        validationError=true
    fi

    if [ $validationError == true ]; then
        End-Script 1
    fi
}

Test-Prerequisites() {
    local versionInstalled=""
    local command=""
    local validationError=false
    
    Write-Log "INFO" "Checking your system and testing prerequisites..."

    command="bash"
    versionInstalled=$("$command" --version | head -n 1)
    Write-Log "DEBUG" "    => Your \"$command\" is available in version \"$versionInstalled\""

    # QNAP specific \
        if [[ "$versionInstalled" =~ "QNAP" ]]; then
            if [ -z "$(Read-INI "$configFile" "qnap_systems" "mandatory_packages_install")" ]; then
                echo "                                  ------------------------------------------------------------------------------------------------------------------------------"
                echo "                                  QNAP SYSTEM DETECTED!"
                echo "                                  ------------------------------------------------------------------------------------------------------------------------------"
                echo "                                  On QNAP systems, additional packages are required to make this script work."
                echo "                                  You can choose to install these packages manually or let this script handle the installation automatically when executed."
                echo "                                  If you opt for manual installation, remember that after each restart of your QNAP, these packages will be removed by default."
                echo "                                      - coreutils-sort"
                echo "                                      - coreutils-cut"
                echo "                                      - grep"
                echo "                                      - jq"
                echo "                                      - sed"
                echo "                                      - wget"
                echo "                                      - gawk"
                read -p "                                  Would you like this script to automatically install the mandatory components every time it runs via entware-ng repository? (yes/no) [Default: no]: " response

                if [ -z "$response" ] || [ "$response" != "yes" ] && [ "$response" != "y" ]; then
                    Write-Log "INFO" "You chose not to install components automatically"
                    Write-Log "INFO" "You can change this behavior in your configuration file \"$configFile\""
                    Write-INI "$configFile" "qnap_systems" "mandatory_packages_install" "manual"
                else
                    Write-INI "$configFile" "qnap_systems" "mandatory_packages_install" "auto"
                fi
            fi
        fi  

        if [ "$(Read-INI "$configFile" "qnap_systems" "mandatory_packages_install")" == "auto" ]; then
            Write-Log "INFO" "       Installing additional packages via entware-ng..."
            wget -O - http://pkg.entware.net/binaries/x86-64/installer/entware_install.sh 2>/dev/null | /bin/sh >/dev/null 2>&1
            /opt/bin/opkg update >/dev/null 2>&1
            /opt/bin/opkg install coreutils-sort >/dev/null 2>&1
            /opt/bin/opkg install coreutils-cut >/dev/null 2>&1
            /opt/bin/opkg install grep >/dev/null 2>&1
            /opt/bin/opkg install jq >/dev/null 2>&1
            /opt/bin/opkg install sed >/dev/null 2>&1
            /opt/bin/opkg install wget >/dev/null 2>&1
            /opt/bin/opkg install gawk >/dev/null 2>&1
        fi
    # QNAP specific /
    
    command="tput"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" -V 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "WARNING" "    => It seems there is no version of \"$command\" installed on your system"
    fi

    command="gawk"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="cut"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="docker"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="grep"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="jq"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="sed"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="wget"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="sort"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "ERROR" "    => Could not find \"$command\""
            validationError=true
        else
            versionInstalled=$("$(Read-INI "$configFile" "paths" "$command")" --version 2>/dev/null | head -n 1)
            Write-Log "DEBUG" "    => Found \"$command\" installed in version \"$versionInstalled\""
        fi
    else
        Write-Log "ERROR" "    => It seems there is no version of \"$command\" installed on your system"
        validationError=true
    fi

    command="sendmail"
    if [ -n "$(Read-INI "$configFile" "paths" "$command")" ]; then
        if ! [ -x "$(Read-INI "$configFile" "paths" "$command")" ]; then
            Write-Log "WARNING" "    => Could not find \"$command\""
        else
            Write-Log "DEBUG" "    => Found \"$command\""
        fi
    elif [ "$(Read-INI "$configFile" "mail" "notifications_enabled")" == "true" ]; then
        Write-Log "WARNING" "    => It seems there is no version of \"$command\" installed on your system"
    fi

    if [ $validationError == true ]; then
        Write-Log "ERROR" "Insufficient system requirements detected"
        End-Script 1
    fi
}

Get-ScriptVersion() {
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local version_line=$(head -n 10 "$0" | $cmd_grep -n "# ## Version" | $cmd_cut -d: -f1)
    local next_line=0

    if [ -n "$version_line" ]; then
        next_line=$((version_line + 1))
        $cmd_sed "${next_line}q;d" "$0" | $cmd_cut -d " " -f2
    else
        echo "Not found"
    fi
}

Get-ContainerProperty() {
    local container_config=$1
    local property=$2
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")

    if ! $cmd_jq -e . >/dev/null 2>&1 <<<"$container_config"; then
        Write-Log "ERROR" "Invalid json data passed to \"Get-ContainerProperty()\""
        return
    fi

    if   [ "$property" == "container_name" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Name' | $cmd_sed 's#^/##' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_hostname" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Config.Hostname' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_state_paused" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].State.Paused' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_labels" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Config.Labels | to_entries[] | "--label \"\(.key)=\(.value)\""' 2>/dev/null | tr '\n' ' ' | $cmd_sed 's/^null$//' | $cmd_sed 's/`/\\`/g')"
        return
    elif [ "$property" == "container_capabilities" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.CapAdd[]' 2>/dev/null | $cmd_sed 's/^/--cap-add=/' | tr '\n' ' ' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_networkMode" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.NetworkMode' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_networkMode_IPv4Address" ]; then
        #echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .IPAMConfig.IPv4Address' | $cmd_sed 's/^null$//')"
        #echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks['\"$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.NetworkMode' | $cmd_sed 's/^null$//')\"'].IPAMConfig.IPv4Address' | $cmd_sed 's/^null$//')"
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks['\"$(Get-ContainerProperty "$container_config" "container_networkMode")\"'].IPAMConfig.IPv4Address' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_networkMode_IPv6Address" ]; then
        #echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .IPAMConfig.IPv6Address' | $cmd_sed 's/^null$//')"
        #echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks['\"$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.NetworkMode' | $cmd_sed 's/^null$//')\"'].IPAMConfig.IPv6Address' | $cmd_sed 's/^null$//')"
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks['\"$(Get-ContainerProperty "$container_config" "container_networkMode")\"'].IPAMConfig.IPv6Address' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_networkMode_MacAddress" ]; then
        #echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .MacAddress' | $cmd_sed 's/^null$//')"
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks['\"$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.NetworkMode' | $cmd_sed 's/^null$//')\"'].MacAddress' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_primaryNetwork_Name" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | keys_unsorted[]' | head -n 1 | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_primaryNetwork_IPv4Address" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .IPAMConfig.IPv4Address' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_primaryNetwork_IPv6Address" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .IPAMConfig.IPv6Address' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_primaryNetwork_MacAddress" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].NetworkSettings.Networks | .[] | .MacAddress' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_restartPolicy_name" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.RestartPolicy.Name' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_restartPolicy_MaximumRetryCount" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_PublishAllPorts" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.PublishAllPorts' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_PortBindings" ]; then
        local PortBindings=$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.PortBindings')
        local PortBindings_count=$(echo "$PortBindings" | $cmd_jq '. | length')
        local host_port_key_name=""
        local host_port=""
        local protocol=""
        local container_port=""
        local PortBindings_sting=""

        if [ "$PortBindings_count" -gt 0 ] && [ -n "$PortBindings_count" ]; then
            for ((i = 0; i < PortBindings_count; i++)); do
                host_port_key_name=$(echo "$PortBindings" | $cmd_jq -r ". | keys_unsorted | .[$i]")
                if [[ $host_port_key_name == */* ]]; then
                    host_port=$(echo "$host_port_key_name" | $cmd_cut -d'/' -f1)
                    protocol=$(echo "$host_port_key_name" | $cmd_cut -d'/' -f2)
                else
                    host_port=$host_port_key_name
                    protocol=""
                fi
                container_port=$(echo "$PortBindings" | $cmd_jq -r ".[\"$host_port_key_name\"][0].HostPort")
                PortBindings_sting+=" --publish $container_port:$host_port"
            done
        fi

        echo "$(echo "$PortBindings_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_Mounts" ]; then
        local mounts=$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.Mounts')
        local mounts_count=$(echo "$mounts" | $cmd_jq '. | length')
        local type=""
        local source=""
        local target=""
        local mounts_sting=""

        if [ "$mounts_count" -gt 0 ] && [ -n "$mounts_count" ]; then
            for ((i = 0; i < mounts_count; i++)); do
                type=$(echo "$mounts" | $cmd_jq -r ".[$i].Type")
                source=$(echo "$mounts" | $cmd_jq -r ".[$i].Source" | $cmd_sed 's/ /\\ /g')
                target=$(echo "$mounts" | $cmd_jq -r ".[$i].Target" | $cmd_sed 's/ /\\ /g')
                mounts_sting+=" --mount type=$type,source=$source,target=$target"
            done
        fi

        echo "$(echo "$mounts_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_envs" ]; then
        local envs=$(echo "$container_config" | $cmd_jq -r '.[0].Config.Env')
        local envs_count=$(echo "$envs" | $cmd_jq '. | length')
        local env=""
        local env_name=""
        local env_value=""
        local envs_sting=""

        if [ "$envs_count" -gt 0 ] && [ -n "$envs_count" ]; then
            for ((i = 0; i < envs_count; i++)); do
                env=$(echo "$envs" | $cmd_jq -r ".[$i]")
                env_name="${env%%=*}"
                env_value="${env#*=}"
                #envs_sting+=" --env $env_name='$env_value'"
                envs_sting+=" --env $env_name=\"$env_value\""
            done
        fi

        echo "$(echo "$envs_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_tmpfs" ]; then
        local tmpfs=$(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.Tmpfs' | $cmd_sed 's/^null$//')
        local tmpfs_values=""
        local tmpfs_sting=""
        
        if [ -n "$tmpfs" ]; then
            tmpfs_values=($(echo "$container_config" | $cmd_jq -r '.[0].HostConfig.Tmpfs | to_entries[] | .key + ":" + .value'))
            for value in "${tmpfs_values[@]}"; do
                tmpfs_sting+=" --tmpfs $value"
            done
        fi

        echo "$(echo "$tmpfs_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_cmd" ]; then
        local cmds=$(echo "$container_config" | $cmd_jq -r '.[0].Config.Cmd')
        local cmds_count=$(echo "$cmds" | $cmd_jq '. | length')
        local cmd=""
        local cmds_sting=""

        if [ "$cmds_count" -gt 0 ] && [ -n "$cmds_count" ]; then
            for ((i = 0; i < cmds_count; i++)); do
                cmd=$(echo "$cmds" | $cmd_jq -r ".[$i]")
                cmds_sting+=" $cmd"
            done
        fi

        echo "$(echo "$cmds_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_image_id" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Image' | $cmd_sed 's#^/##' | $cmd_awk -F: '{print $2}' | $cmd_cut -b 1-13 | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_image_name" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Config.Image' | $cmd_cut -d':' -f1 | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "container_image_tag" ]; then
        echo "$(echo "$container_config" | $cmd_jq -r '.[0].Config.Image' | $cmd_cut -d':' -f2 | $cmd_sed 's/^null$//')"
        return
    else
        Write-Log "ERROR" "Unknown property requested: $property"
    fi
}

Get-ImageProperty() {
    local image_config=$1
    local property=$2
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")

    if ! $cmd_jq -e . >/dev/null 2>&1 <<<"$image_config"; then
        Write-Log "ERROR" "Invalid json data passed to \"Get-ImageProperty()\""
        return
    fi

    if   [ "$property" == "image_repoDigests" ]; then
        local digests=$(echo "$image_config" | $cmd_jq -r '.[0].RepoDigests')
        local digests_count=$(echo "$digests" | $cmd_jq '. | length')
        local digest=""
        local digests_sting=""

        if [ "$digests_count" -gt 0 ] && [ -n "$digests_count" ]; then
            for ((i = 0; i < digests_count; i++)); do
                digest=$(echo "$digests" | $cmd_jq -r ".[$i]" | $cmd_cut -d':' -f2)
                digests_sting+=" $digest"
            done
        fi

        echo "$(echo "$digests_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "image_labels" ]; then
        echo "$(echo "$image_config" | $cmd_jq -r '.[0].Config.Labels | to_entries[] | "--label \"\(.key)=\(.value)\""' 2>/dev/null | tr '\n' ' ' | $cmd_sed 's/^null$//' | $cmd_sed 's/`/\\`/g')"
        return
    elif [ "$property" == "image_envs" ]; then
        local envs=$(echo "$image_config" | $cmd_jq -r '.[0].Config.Env')
        local envs_count=$(echo "$envs" | $cmd_jq '. | length')
        local env=""
        local env_name=""
        local env_value=""
        local envs_sting=""

        if [ "$envs_count" -gt 0 ] && [ -n "$envs_count" ]; then
            for ((i = 0; i < envs_count; i++)); do
                env=$(echo "$envs" | $cmd_jq -r ".[$i]")
                env_name="${env%%=*}"
                env_value="${env#*=}"
                #envs_sting+=" --env $env_name='$env_value'"
                envs_sting+=" --env $env_name=\"$env_value\""
            done
        fi

        echo "$(echo "$envs_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    elif [ "$property" == "image_cmd" ]; then
        local cmds=$(echo "$image_config" | $cmd_jq -r '.[0].Config.Cmd')
        local cmds_count=$(echo "$cmds" | $cmd_jq '. | length')
        local cmd=""
        local cmds_sting=""

        if [ "$cmds_count" -gt 0 ] && [ -n "$cmds_count" ]; then
            for ((i = 0; i < cmds_count; i++)); do
                cmd=$(echo "$cmds" | $cmd_jq -r ".[$i]")
                cmds_sting+=" $cmd"
            done
        fi

        echo "$(echo "$cmds_sting" | $cmd_sed -e 's/^[[:space:]]*//' | $cmd_sed 's/^null$//')"
        return
    else
        Write-Log "ERROR" "Unknown property requested: $property"
    fi
}

Get-ContainerPropertyUnique() {
    #############################
    ## This function compares some container properties with the default properties of the original image and gives back a string with a delta
    #############################
    local value_container=$1
    local value_image=$2
    local property=$3
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")

    if   [ "$property" == "unique_labels" ]; then
        local container_labels_seperated=$(echo "$value_container" | $cmd_sed 's/--label /\n/g')
        local image_labels_seperated=$(echo "$value_image" | $cmd_sed 's/--label /\n/g')
        
        IFS=$'\n' read -rd '' -a container_labels_array <<<"$container_labels_seperated"
        IFS=$'\n' read -rd '' -a image_labels_array <<<"$image_labels_seperated"
        for container_label in "${container_labels_array[@]}"; do
            local container_label_name=$(echo "$container_label" | $cmd_cut -d= -f1 | $cmd_sed 's/^"\(.*\)/\1/')
            #local container_label_value=$(echo "$container_label" | $cmd_cut -d= -f2 | $cmd_sed 's/\(.*\)" $/\1/') # In case the label value has a '='-Sign in it, this causes an issue
            local container_label_value=$(echo "$container_label" | $cmd_sed 's/^[^=]*=//' | $cmd_sed 's/\(.*\)" $/\1/')
            local container_label_name_isUnique=true
            
            for image_label in "${image_labels_array[@]}"; do
                local image_label_name=$(echo "$image_label" | $cmd_cut -d= -f1 | $cmd_sed 's/^"\(.*\)/\1/')
                local image_label_value=$(echo "$image_label" | $cmd_cut -d= -f2 | $cmd_sed 's/\(.*\)" $/\1/')

                if [ "$image_label_name" == "$container_label_name" ]; then
                    container_label_name_isUnique=false
                    break
                fi
            done

            if [ "$container_label_name_isUnique" == true ]; then
                unique_labels+="--label \"$container_label_name=$container_label_value\" "  
            fi
        done

        unique_labels=$(echo "$unique_labels" | $cmd_sed 's/\(.*\) $/\1/')

        echo "$unique_labels"
        return
    elif [ "$property" == "unique_envs" ]; then
        local container_variables_seperated=$(echo "$value_container" | $cmd_sed 's/--env /\n/g')
        local image_variables_seperated=$(echo "$value_image" | $cmd_sed 's/--env /\n/g')
        
        IFS=$'\n' read -rd '' -a container_variables_array <<<"$container_variables_seperated"
        IFS=$'\n' read -rd '' -a image_variables_array <<<"$image_variables_seperated"
        for container_variable in "${container_variables_array[@]}"; do
            local container_variable_name=$(echo "$container_variable" | $cmd_cut -d= -f1 | $cmd_sed 's/^"\(.*\)/\1/')
            # local container_variable_value=$(echo "$container_variable" | $cmd_cut -d= -f2 | $cmd_sed 's/ *"$//') # In case the variable value has a '='-Sign in it, this causes an issue
            local container_variable_value=$(echo "$container_variable" | $cmd_sed 's/^[^=]*=//' | $cmd_sed 's/ *"$//')
            local container_variable_name_isUnique=true
            
            for image_variable in "${image_variables_array[@]}"; do
                local image_variable_name=$(echo "$image_variable" | $cmd_cut -d= -f1 | $cmd_sed 's/^"\(.*\)/\1/')
                local image_variable_value=$(echo "$image_variable" | $cmd_sed 's/^[^=]*=//' | $cmd_sed 's/ *"$//')

                if [ "$image_variable_name" == "$container_variable_name" ]; then
                    container_variable_name_isUnique=false
                    break
                fi
            done

            if [ "$container_variable_name_isUnique" == true ]; then
                unique_variables+="--env $container_variable_name=$container_variable_value"
            fi
        done

        unique_variables=$(echo "$unique_variables" | $cmd_sed 's/\(.*\) $/\1/')

        echo "$unique_variables"
        return
    else
        Write-Log "ERROR" "Unknown property requested: $property"
    fi
}

New-DockerHubImageTagFilter() {
    local template="$1"
    local group=$2
    local regexFilter=""
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local i=0
    local seperator_count=0
    local seperator_count_max=0
    
    if   [ "$group" == "by_major" ]; then
        seperator_count_max=1
    elif [ "$group" == "by_minor" ]; then
        seperator_count_max=2
    elif [ "$group" == "by_patch" ]; then
        seperator_count_max=3
    elif [ "$group" == "by_build" ]; then
        seperator_count_max=4
    fi
    
    if [ -n "$group" ]; then
        for ((i=$i; i<${#template}; i++)); do
            char="${template:$i:1}"
            if [[ "$char" == "." || "$char" == "-" ]]; then
                (( seperator_count++ ))
                if (( seperator_count == seperator_count_max )); then
                    break
                fi
            fi
            regexFilter+="${char}"
        done
    fi

    for ((i=$i; i<${#template}; i++)); do
        char="${template:$i:1}"
        if [[ "$char" =~ [0-9] ]]; then
            if [[ "$last_char_type" != "integer" ]]; then
                regexFilter="${regexFilter}[0-9]+"
                last_char_type="integer"
            fi
        else
            regexFilter="${regexFilter}${char}"
            last_char_type="string"
        fi
    done

    echo "^$regexFilter$"
    return
}

Extract-VersionPart() {
    local template=$1
    local version=$2
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local dot_count=$(echo "$template" | $cmd_grep -o '\.' | wc -l)

    if   [ -n "$template" ] && [ "$version" == "major" ]; then
        if [ "$dot_count" -lt 3 ]; then
            echo "$(echo $template | $cmd_cut -d'.' -f1 | $cmd_cut -d'-' -f1 | tr -dc '0-9')"
        else
            echo "$(echo $template | $cmd_cut -d'.' -f1 | tr -dc '0-9')"
        fi
        return
    elif [ -n "$template" ] && [ "$version" == "minor" ]; then
        if [ "$dot_count" -lt 3 ]; then
            echo "$(echo $template | $cmd_cut -d'.' -f2 | $cmd_cut -d'-' -f2 | tr -dc '0-9')"
        else
            echo "$(echo $template | $cmd_cut -d'.' -f2 | tr -dc '0-9')"
        fi
        return
    elif [ -n "$template" ] && [ "$version" == "patch" ]; then
        if [ "$dot_count" -lt 3 ]; then
            echo "$(echo $template | $cmd_cut -d'.' -f3 | $cmd_cut -d'-' -f3 | tr -dc '0-9')"
        else
            echo "$(echo $template | $cmd_cut -d'.' -f3 | tr -dc '0-9')"
        fi
        return
    elif [ -n "$template" ] && [ "$version" == "build" ]; then
        if [ "$dot_count" -lt 3 ]; then
            echo "$(echo $template | $cmd_cut -d'.' -f4 | $cmd_cut -d'-' -f4 | tr -dc '0-9')"
        else
            echo "$(echo $template | $cmd_cut -d'.' -f4 | tr -dc '0-9')"
        fi
        return
    # else
    #     Write-Log "ERROR" "Unknown version type requested: $version"
    fi
}

Get-EffectiveUpdateRule() {
    local container_name=$1
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local update_rule_name=""

    IFS=' ' read -ra update_rules <<< "$(Read-INI "$configFile" "general" "update_rules")"
    for update_rule in "${update_rules[@]}"; do
        update_rule_name=$(echo "$update_rule" | $cmd_grep -o '^[^[]*')
        if [ "$update_rule_name" == "$container_name" ]; then
            effective_update_rule=$update_rule
        elif [ "$update_rule_name" == "*" ]; then
            default_update_rule=$update_rule
        fi
    done
    [ -z "$effective_update_rule" ] && effective_update_rule=$default_update_rule

    echo "$effective_update_rule"
    return
}

Get-UpdatePermit() {
    local container_name=$1
    local image_tag_name_current=$2
    local image_tag_name_next=$3
    local image_tag_name_latest_related=$4
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local effective_update_rule="$(Get-EffectiveUpdateRule "container_name")"
    local compare_operator=""
    local compare_val=""
    local rule_major=$(echo "$effective_update_rule" | $cmd_cut -d '[' -f2 | $cmd_cut -d '.' -f1)
    local rule_minor=$(echo "$effective_update_rule" | $cmd_cut -d '[' -f2 | $cmd_cut -d '.' -f2)
    local rule_patch=$(echo "$effective_update_rule" | $cmd_cut -d '[' -f2 | $cmd_cut -d '.' -f3 | $cmd_cut -d '-' -f1)
    local rule_build=$(echo "$effective_update_rule" | $cmd_cut -d '-' -f2 | $cmd_cut -d ',' -f1)
    local rule_digests=$(echo "$effective_update_rule" | $cmd_cut -d ',' -f2 | $cmd_cut -d ']' -f1)
    local major_current=$(Extract-VersionPart "$image_tag_name_current" "major")
    local minor_current=$(Extract-VersionPart "$image_tag_name_current" "minor")
    local patch_current=$(Extract-VersionPart "$image_tag_name_current" "patch")
    local build_current=$(Extract-VersionPart "$image_tag_name_current" "build")
    local major_next=$(Extract-VersionPart "$image_tag_name_next" "major")
    local minor_next=$(Extract-VersionPart "$image_tag_name_next" "minor")
    local patch_next=$(Extract-VersionPart "$image_tag_name_next" "patch")
    local build_next=$(Extract-VersionPart "$image_tag_name_next" "build")
    local major_latest=$(Extract-VersionPart "$image_tag_name_latest_related" "major")
    local minor_latest=$(Extract-VersionPart "$image_tag_name_latest_related" "minor")
    local patch_latest=$(Extract-VersionPart "$image_tag_name_latest_related" "patch")
    local build_latest=$(Extract-VersionPart "$image_tag_name_latest_related" "build")

    # Digest Rule Definition Analyzis
        if [ "$image_tag_name_current" == "$image_tag_name_next" ]; then
            echo "$rule_digests"
            return
        fi

    # Major Rule Definition Analyzis
        if [[ "$major_current" != "$major_next" ]]; then
            if [[ "$rule_major" =~ ^[0-9]+$ ]]; then
                # If the rule for major updates is solely numeric, we can assume that there is no more precise rule definition that
                if ((major_latest - major_current >= rule_major)) && [ "$rule_major" -gt 0 ]; then
                    echo true
                    return
                fi
            else
                # If the value is not exclusively numeric, we need to conduct a more precise rule definition analysis
                rule_major_main=$(echo "$rule_major" | $cmd_awk -F '&\\(' '{print $1}') # e.g. 2
                rule_set_major=$(echo "$rule_major" | $cmd_awk -F '&\\(' '{print $2}' | $cmd_sed 's/)$//') # e.g. Currently supported values for more precised rules are single ones, like: "M>0", "m>0", "p>0" or "b>0". In a future version combinations like "m>0|p=0&b<2" are planned
                compare_operator="${rule_set_major:1:1}"
                compare_val="$(echo $rule_set_major | $cmd_sed 's/[^0-9]*//g')"
                if ((major_latest - major_current >= rule_major_main)); then
                    if [ $(echo $rule_set_major | $cmd_cut -c 1) == "b" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_major | $cmd_cut -c 1) == "p" ]; then
                        if [[ $patch_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$patch_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$patch_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$patch_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_major | $cmd_cut -c 1) == "m" ]; then
                        if [[ $minor_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$minor_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$minor_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$minor_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_major | $cmd_cut -c 1) == "M" ]; then
                        if [[ $major_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$major_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$major_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$major_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    fi
                fi
            fi

            echo false
            return
        fi

    # Minor Rule Definition Analyzis
        if [[ "$minor_current" != "$minor_next" ]]; then
            if [[ "$rule_minor" =~ ^[0-9]+$ ]]; then
                # If the rule for minor updates is solely numeric, we can assume that there is no more precise rule definition that
                if ((minor_latest - minor_current >= rule_minor)) && [ "$rule_minor" -gt 0 ]; then
                    echo true
                    return
                fi
            else
                # If the value is not exclusively numeric, we need to conduct a more precise rule definition analysis
                rule_minor_main=$(echo "$rule_minor" | $cmd_awk -F '&\\(' '{print $1}') # e.g. 2
                rule_set_minor=$(echo "$rule_minor" | $cmd_awk -F '&\\(' '{print $2}' | $cmd_sed 's/)$//') # e.g. Currently supported values for more precised rules are single ones, like: "M>0", "m>0", "p>0" or "b>0". In a future version combinations like "m>0|p=0&b<2" are planned
                compare_operator="${rule_set_minor:1:1}"
                compare_val="$(echo $rule_set_minor | $cmd_sed 's/[^0-9]*//g')"
                if ((minor_latest - minor_current >= rule_minor_main)); then
                    if [ $(echo $rule_set_minor | $cmd_cut -c 1) == "b" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_minor | $cmd_cut -c 1) == "p" ]; then
                        if [[ $patch_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$patch_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$patch_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$patch_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_minor | $cmd_cut -c 1) == "m" ]; then
                        if [[ $minor_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$minor_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$minor_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$minor_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_minor | $cmd_cut -c 1) == "M" ]; then
                        if [[ $minor_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$minor_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$minor_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$minor_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    fi
                fi
            fi

            echo false
            return
        fi

    # Patch Rule Definition Analyzis
        if [[ "$patch_current" != "$patch_next" ]]; then
            if [[ "$rule_patch" =~ ^[0-9]+$ ]]; then
                # If the rule for patch updates is solely numeric, we can assume that there is no more precise rule definition that
                if ((patch_latest - patch_current >= rule_patch)) && [ "$rule_patch" -gt 0 ]; then
                    echo true
                    return
                fi
            else
                # If the value is not exclusively numeric, we need to conduct a more precise rule definition analysis
                rule_patch_main=$(echo "$rule_patch" | $cmd_awk -F '&\\(' '{print $1}') # e.g. 2
                rule_set_patch=$(echo "$rule_patch" | $cmd_awk -F '&\\(' '{print $2}' | $cmd_sed 's/)$//') # e.g. Currently supported values for more precised rules are single ones, like: "M>0", "m>0", "p>0" or "b>0". In a future version combinations like "m>0|p=0&b<2" are planned
                compare_operator="${rule_set_patch:1:1}"
                compare_val="$(echo $rule_set_patch | $cmd_sed 's/[^0-9]*//g')"
                if ((patch_latest - patch_current >= rule_patch_main)); then
                    if [ $(echo $rule_set_patch | $cmd_cut -c 1) == "b" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_patch | $cmd_cut -c 1) == "p" ]; then
                        if [[ $patch_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$patch_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$patch_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$patch_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_patch | $cmd_cut -c 1) == "m" ]; then
                        if [[ $patch_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$patch_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$patch_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$patch_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_patch | $cmd_cut -c 1) == "M" ]; then
                        if [[ $patch_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$patch_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$patch_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$patch_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    fi
                fi
            fi

            echo false
            return
        fi

    # Build Rule Definition Analyzis
        if [[ "$build_current" != "$build_next" ]]; then
            if [[ "$rule_build" =~ ^[0-9]+$ ]]; then
                # If the rule for build updates is solely numeric, we can assume that there is no more precise rule definition that
                if ((build_latest - build_current >= rule_build)) && [ "$rule_build" -gt 0 ]; then
                    echo true
                    return
                fi
            else
                # If the value is not exclusively numeric, we need to conduct a more precise rule definition analysis
                rule_build_main=$(echo "$rule_build" | $cmd_awk -F '&\\(' '{print $1}') # e.g. 2
                rule_set_build=$(echo "$rule_build" | $cmd_awk -F '&\\(' '{print $2}' | $cmd_sed 's/)$//') # e.g. Currently supported values for more precised rules are single ones, like: "M>0", "m>0", "p>0" or "b>0". In a future version combinations like "m>0|p=0&b<2" are planned
                compare_operator="${rule_set_build:1:1}"
                compare_val="$(echo $rule_set_build | $cmd_sed 's/[^0-9]*//g')"
                if ((build_latest - build_current >= rule_build_main)); then
                    if [ $(echo $rule_set_build | $cmd_cut -c 1) == "b" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_build | $cmd_cut -c 1) == "p" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_build | $cmd_cut -c 1) == "m" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    elif [ $(echo $rule_set_build | $cmd_cut -c 1) == "M" ]; then
                        if [[ $build_latest =~ ^[0-9]+$ ]] && [[ $compare_val =~ ^[0-9]+$ ]]; then
                            case $compare_operator in
                                ">") if [ "$build_latest" -gt "$compare_val" ]; then echo true && return; fi ;;
                                "<") if [ "$build_latest" -lt "$compare_val" ]; then echo true && return; fi ;;
                                "=") if [ "$build_latest" -eq "$compare_val" ]; then echo true && return; fi ;;
                                *) echo "Invalid comparison operator passed";;
                            esac
                        fi
                    fi
                fi
            fi

            echo false
            return
        fi

    echo false  
    return
}

Get-DockerHubImageURL() {
    local image_name=$1
    local docker_hub_api_url=$(Read-INI "$configFile" "general" "docker_hub_api_url")

    if [[ $image_name == *'/'* ]]; then
        echo "$docker_hub_api_url/repositories/${image_name}"
        return
    else
        echo "$docker_hub_api_url/repositories/library/${image_name}"
        return
    fi
}

Get-DockerHubImageTags() {
    local image_name=$1
    local docker_hub_api_image_tags_page_size_limit=$(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_size_limit")
    local docker_hub_api_image_tags_page_crawl_limit=$(Read-INI "$configFile" "general" "docker_hub_api_image_tags_page_crawl_limit")
    local url=""
    local image_tags=""
    local cmd_wget=$(Read-INI "$configFile" "paths" "wget")

    for ((page=1; page<=$docker_hub_api_image_tags_page_crawl_limit; page++)); do
        url="$(Get-DockerHubImageURL "$container_image_name")/tags?page_size=${docker_hub_api_image_tags_page_size_limit}&page=${page}"
        response=$($cmd_wget -q "$url" --no-check-certificate -O - 2>&1)
        if [[ -z $response ]]; then
            break
        else
            image_tags+="$response"
        fi
    done

    #echo "$(echo $image_tags | tr -d '\n' | tr -d ' ')"
    echo "$(echo $image_tags | tr -d '\n')"
    return
}

Get-DockerHubImageTagNames() {
    local jsondata=$1
    local returnType=$2
    local imageTagNameFilter=$3
    local currentContainerImageTag=$4
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local cmd_sort=$(Read-INI "$configFile" "paths" "sort")
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")

    if ! $cmd_jq -e . >/dev/null 2>&1 <<<"$jsondata"; then
        Write-Log "ERROR" "Invalid json data passed to \"Get-DockerHubImageTagNames()\""
        return
    fi

    if   [ -z "$returnType" ]; then
        echo $(echo "$jsondata" | $cmd_jq -r '.results[].name' | $cmd_sed 's/^ *//')
        return
    fi
}

Get-DockerHubImageTagProperty() {
    local jsondata=$1
    local imageTagName=$2
    local property=$3
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")

    if ! $cmd_jq -e . >/dev/null 2>&1 <<<"$jsondata"; then
        Write-Log "ERROR" "Invalid json data passed to \"Get-DockerHubImageTagProperty()\""
        return
    fi

    if   [ "$property" == "docker_hub_image_tag_digest" ]; then
        #echo $(echo "$jsondata" | $cmd_jq -r --arg name "$imageTagName" '.results[] | select(.name == $name) | .images[].digest' | $cmd_sed 's/^null$//') # gets all digests for all architectures
        echo $(echo "$jsondata" | $cmd_jq -r --arg name "$imageTagName" '.results[] | select(.name == $name) | .digest' | $cmd_cut -d':' -f2 | $cmd_sed 's/^null$//')
        return
    else
        Write-Log "ERROR" "Unknown property requested: $property"
    fi
}

Get-AvailableUpdates() {
    local updateType=$1
    local cmd_awk=$(Read-INI "$configFile" "paths" "gawk")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local cmd_sort=$(Read-INI "$configFile" "paths" "sort")

    if   [ "$updateType" == "all" ]; then
        local docker_hub_image_tag_names=$2
        local filter=$3
        local container_image_tag=$4
        
        echo $(echo "$docker_hub_image_tag_names" | tr ' ' '\n' | $cmd_grep -E "$filter" | tr ' ' '\n' | $cmd_sort -rV | tr '\n' ' ' | $cmd_sed "s/$container_image_tag.*//")
        return
    fi

    if   [ "$updateType" == "major" ]; then
        local docker_hub_image_tag_names=$(echo $2 | tr ' ' '\n')
        local container_image_tag=$3
        local return_request=$4
        local major_version_current=$(Extract-VersionPart $container_image_tag "major")

        for tag in $docker_hub_image_tag_names; do
            major_version_online=$(Extract-VersionPart $tag "major")
            if [ "$return_request" == "next" ]; then
                if [ "$major_version_online" -le "$major_version_current" ]; then
                    break
                else
                    return_value=$tag
                fi
            elif [ "$return_request" == "latest" ]; then
                return_value=$tag
                break
            fi
        done

        echo $return_value
        return
    fi

    if   [ "$updateType" == "minor" ]; then
        local docker_hub_image_tag_names=$(echo $2 | tr ' ' '\n')
        local container_image_tag=$3
        local return_request=$4
        local major_version_current=$(Extract-VersionPart $container_image_tag "major")
        local minor_version_current=$(Extract-VersionPart $container_image_tag "minor")

        for tag in $docker_hub_image_tag_names; do
            major_version_online=$(Extract-VersionPart $tag "major")
            minor_version_online=$(Extract-VersionPart $tag "minor")
            if [ "$return_request" == "next" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -le "$minor_version_current" ]; then
                    break
                else
                    if [ "$major_version_online" -eq "$major_version_current" ]; then
                        return_value=$tag
                    else
                        return_value=""
                    fi
                fi
            elif [ "$return_request" == "latest" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ]; then
                    return_value=$tag
                    break
                else
                    return_value=""
                fi
            fi
        done

        echo $return_value
        return
    fi

    if   [ "$updateType" == "patch" ]; then
        local docker_hub_image_tag_names=$(echo $2 | tr ' ' '\n')
        local container_image_tag=$3
        local return_request=$4
        local major_version_current=$(Extract-VersionPart $container_image_tag "major")
        local minor_version_current=$(Extract-VersionPart $container_image_tag "minor")
        local patch_version_current=$(Extract-VersionPart $container_image_tag "patch")

        for tag in $docker_hub_image_tag_names; do
            major_version_online=$(Extract-VersionPart $tag "major")
            minor_version_online=$(Extract-VersionPart $tag "minor")
            patch_version_online=$(Extract-VersionPart $tag "patch")
            if [ "$return_request" == "next" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ] && [ "$patch_version_online" -le "$patch_version_current" ]; then
                    break
                else
                    if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ]; then
                        return_value=$tag
                    else
                        return_value=""
                    fi
                fi
            elif [ "$return_request" == "latest" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ]; then
                    return_value=$tag
                    break
                else
                    return_value=""
                fi
            fi
        done

        echo $return_value
        return
    fi

    if   [ "$updateType" == "build" ]; then
        local docker_hub_image_tag_names=$(echo $2 | tr ' ' '\n')
        local container_image_tag=$3
        local return_request=$4
        local major_version_current=$(Extract-VersionPart $container_image_tag "major")
        local minor_version_current=$(Extract-VersionPart $container_image_tag "minor")
        local patch_version_current=$(Extract-VersionPart $container_image_tag "patch")
        local build_version_current=$(Extract-VersionPart $container_image_tag "build")

        for tag in $docker_hub_image_tag_names; do
            major_version_online=$(Extract-VersionPart $tag "major")
            minor_version_online=$(Extract-VersionPart $tag "minor")
            patch_version_online=$(Extract-VersionPart $tag "patch")
            build_version_online=$(Extract-VersionPart $tag "build")
            if [ "$return_request" == "next" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ] && [ "$patch_version_online" -eq "$patch_version_current" ] && [ "$build_version_online" -le "$build_version_current" ]; then
                    break
                else
                    if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ] && [ "$patch_version_online" -eq "$patch_version_current" ]; then
                        return_value=$tag
                    else
                        return_value=""
                    fi
                fi
            elif [ "$return_request" == "latest" ]; then
                if [ "$major_version_online" -eq "$major_version_current" ] && [ "$minor_version_online" -eq "$minor_version_current" ] && [ "$patch_version_online" -eq "$patch_version_current" ]; then
                    return_value=$tag
                    break
                else
                    return_value=""
                fi
            fi
        done

        echo $return_value
        return
    fi

    if   [ "$updateType" == "digest" ]; then
        local image_repoDigests=$2
        local docker_hub_image_tag_digest=$3

        if [ -n "$image_repoDigests" ] && [ -n "$docker_hub_image_tag_digest" ]; then
            if echo "$docker_hub_image_tag_digest" | $cmd_grep -q "\<$image_repoDigests\>"; then
                echo false
                return
            else
                echo true
                return
            fi
        else
            echo false
            Write-Log "WARNING" "                => An empty value was passed to \"Get-AvailableUpdates()\" - Either the Image Repository Digests, or the Docker Hub Image Digest was not found"
            return
        fi
    fi
}

Perform-ImageUpdate() {
    local update_type="$1"
    local container_name="$2"
    local container_state_paused="$3"
    local container_restartPolicy_name="$4"
    local image_name="$5"
    local docker_run_cmd="$6"
    local image_tag_old="$7"
    local image_tag_new="$8"
    local test_mode=$(Read-INI "$configFile" "general" "test_mode")
    local cmd_docker=$(Read-INI "$configFile" "paths" "docker")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local cmd_grep=$(Read-INI "$configFile" "paths" "grep")
    local image_pulled_successfully=false
    local container_renamed_successfully=false
    local new_container_started_successfully=false
    local old_container_stopped_successfully=false
    local datetime=$(date +%Y-%m-%d_%H-%M)
    local container_update_validation_time=$(Read-INI "$configFile" "general" "container_update_validation_time")
    local container_update_pre_scripts_folder=$(Read-INI "$configFile" "general" "pre_scripts_folder")
    local container_update_post_scripts_folder=$(Read-INI "$configFile" "general" "post_scripts_folder")
    local container_update_pre_script="$container_update_pre_scripts_folder/$container_name.sh"
    local container_update_post_script="$container_update_post_scripts_folder/$container_name.sh"
    local container_name_backed_up="${container_name}_bak_$(date +%Y-%m-%d_%H-%M)"
    local result=0
    local this_errors_count=0
    [ "$update_type" == "digest" ] && image_tag_new="$image_tag_old"

    if [ -n "$container_update_pre_scripts_folder" ] && [ -n "$container_update_pre_script" ]; then
        mkdir -p "$container_update_pre_scripts_folder" 2>/dev/null
        touch "$container_update_pre_script" 2>/dev/null
        chmod +w "$container_update_pre_script" 2>/dev/null
        chmod +x "$container_update_pre_script" 2>/dev/null
    fi

    if [ -n "$container_update_post_scripts_folder" ] && [ -n "$container_update_post_script" ]; then
        mkdir -p "$container_update_post_scripts_folder" 2>/dev/null
        touch "$container_update_post_script" 2>/dev/null
        chmod +w "$container_update_post_script" 2>/dev/null
        chmod +x "$container_update_post_script" 2>/dev/null
    fi

    Write-Log "INFO"  "    <print_line>"
    Write-Log "INFO"  "    | UPDATE PROGRESS"
    Write-Log "INFO"  "    <print_line>"

    [ "$test_mode" == false ] && [ "$update_type" == "digest" ] && Write-Log "INFO" "       Performing a $update_type update for $container_name ($image_name:$image_tag_old)..."
    [ "$test_mode" == true  ] && [ "$update_type" == "digest" ] && Write-Log "INFO" "       Simulating a $update_type update for $container_name ($image_name:$image_tag_old)..."
    [ "$test_mode" == false ] && [ "$update_type" != "digest" ] && Write-Log "INFO" "       Performing a $update_type update for $container_name ($image_name:$image_tag_old to $image_name:$image_tag_new)..."
    [ "$test_mode" == true  ] && [ "$update_type" != "digest" ] && Write-Log "INFO" "       Simulating a $update_type update for $container_name ($image_name:$image_tag_old to $image_name:$image_tag_new)..."
    
    # Pull new image
    [ "$test_mode" == false ] && Write-Log "INFO"  "           Pulling new image from Docker Hub $image_name:$image_tag_new..."
    [ "$test_mode" == true  ] && Write-Log "INFO"  "           Simulating image pull from Docker Hub for $image_name:$image_tag_new..."
    [ "$test_mode" == false ] && { $cmd_docker pull $image_name:$image_tag_new > /dev/null; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ $result -eq 0 ] && image_pulled_successfully=true  && Write-Log "DEBUG" "             => Image successfully pulled"
    [ "$test_mode" == false ] && [ $result -ne 0 ] && image_pulled_successfully=false && Write-Log "ERROR" "             => Failed to pull image: $result"

    # Executing pre script
    if [ -s "$container_update_pre_script" ]; then
        [ "$test_mode" == false ] && Write-Log "INFO" "           Executing pre script $container_update_pre_script..."
        [ "$test_mode" == true ]  && Write-Log "INFO" "           Would execute pre script $container_update_pre_script..."
            if [ "$test_mode" == false ]; then 
                chmod +x "$container_update_pre_script" 2>/dev/null
                while IFS= read -r line; do
                    Write-Log "INFO" "           | $container_update_pre_script: $line"
                done < <("$container_update_pre_script")
            fi
    fi

    # Rename old container
    datetime=$(date +%Y-%m-%d_%H-%M)
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && Write-Log "INFO"  "           Renaming current docker container from $container_name to $container_name_backed_up..."
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true ] && { $cmd_docker rename "$container_name" "$container_name_backed_up" > /dev/null; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ $result -eq 0 ] && container_renamed_successfully=true  && Write-Log "DEBUG" "             => Container successfully renamed"
    [ "$test_mode" == false ] && [ $result -ne 0 ] && container_renamed_successfully=false && Write-Log "ERROR" "             => Failed to rename container: $result"

    # Disable old containers start up policy
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && Write-Log "INFO"  "           Disabling automatic startup for $container_name_backed_up..."
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && { $cmd_docker update "$container_name_backed_up" --restart no > /dev/null; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && [ $result -eq 0 ] && Write-Log "DEBUG" "             => Successfully updated startup policy"
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && [ $result -ne 0 ] && Write-Log "ERROR" "             => Failed to update startup policy: $result"

    # Stop old container
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && Write-Log "INFO"  "           Stopping $container_name_backed_up..."
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && { $cmd_docker stop "$container_name_backed_up" > /dev/null; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && [ $result -eq 0 ] && old_container_stopped_successfully=true  && Write-Log "DEBUG" "             => Successfully stopped container"
    [ "$test_mode" == false ] && [ "$container_renamed_successfully" == true  ] && [ $result -ne 0 ] && old_container_stopped_successfully=false && Write-Log "ERROR" "             => Failed stop old container: $result"

    # Run new container
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && [ "$container_renamed_successfully" == true  ] && [ "$old_container_stopped_successfully" == true  ] && Write-Log "INFO"  "           Executing docker run command..."
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && [ "$container_renamed_successfully" == true  ] && [ "$old_container_stopped_successfully" == true  ] && Write-Log "DEBUG" "             => $docker_run_cmd"
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && [ "$container_renamed_successfully" == true  ] && [ "$old_container_stopped_successfully" == true  ] && { eval "$docker_run_cmd" > /dev/null; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && [ "$container_renamed_successfully" == true  ] && [ "$old_container_stopped_successfully" == true  ] && [ $result -eq 0 ] && new_container_started_successfully=true  && Write-Log "DEBUG" "             => New container started successfully"
    [ "$test_mode" == false ] && [ "$image_pulled_successfully" == true  ] && [ "$container_renamed_successfully" == true  ] && [ "$old_container_stopped_successfully" == true  ] && [ $result -ne 0 ] && new_container_started_successfully=false && Write-Log "ERROR" "             => Failed to start new container: $result"
    [ "$test_mode" == true  ] && Write-Log "INFO"  "           Docker command that would be executed: $docker_run_cmd"

    # Validate the state of the new container
    [ "$test_mode" == false ] && [ "$new_container_started_successfully" == true  ] && Write-Log "INFO"  "           Waiting for the duration of $container_update_validation_time seconds to validate the state of $container_name..."
    [ "$test_mode" == false ] && [ "$new_container_started_successfully" == true  ] && sleep $((container_update_validation_time + 2))

    if [ "$test_mode" == false ] && [ "$new_container_started_successfully" == true  ]; then
        Write-Log "INFO" "           Validating state and uptime of $container_name..."
        if $cmd_docker ps --format "{{.Names}}" | $cmd_grep -wq "$container_name"; then
            local container_start_time=$(echo $($cmd_docker inspect --format '{{.State.StartedAt}}' $container_name) | $cmd_sed 's/T/ /;s/\..*Z//')
            local container_start_seconds=$(date -d "$container_start_time" +%s)
            local current_time=$(date -u "+%Y-%m-%d %H:%M:%S")
            local current_time_seconds=$(date -d "$current_time" +%s)
            local elapsed_time=$((current_time_seconds - container_start_seconds))
            if [ "$elapsed_time" -gt "$container_update_validation_time" ]; then
                Write-Log "DEBUG" "             => The container $container_name has been started since $elapsed_time seconds - This assumes everything worked well during the update process"
                new_container_started_successfully=true
            else
                Write-Log "ERROR" "             => The container $container_name has been started since just $elapsed_time seconds - This assumes something went wrong during the update process"
                new_container_started_successfully=false
            fi
        else
            Write-Log "ERROR" "             => The container $container_name does not exist or is not started at the moment - This assumes something went wrong during the update process"
            new_container_started_successfully=false
        fi
    fi

    # Executing post script
    if [ -s "$container_update_post_script" ] && [ "$new_container_started_successfully" == true ]; then
        [ "$test_mode" == false ] && Write-Log "INFO" "           Executing post script $container_update_post_script..."
        [ "$test_mode" == true ]  && Write-Log "INFO" "           Would execute post script $container_update_post_script..."
            if [ "$test_mode" == false ]; then 
                chmod +x "$container_update_post_script" 2>/dev/null
                while IFS= read -r line; do
                    Write-Log "INFO" "           | $container_update_post_script: $line"
                done < <("$container_update_post_script")
            fi
    fi

    # Pausing new container if the old container also was in paused state
    [ "$test_mode" == false ] && [ "$new_container_started_successfully" == true ] && [ "$container_state_paused" == true ] && Write-Log "INFO" "           Pausing $container_name..."
    [ "$test_mode" == false ] && [ "$new_container_started_successfully" == true ] && [ "$container_state_paused" == true ] && { $cmd_docker pause $container_name; result=$?; } || result=$?
    [ "$test_mode" == false ] && [ $result -eq 0 ] && [ "$new_container_started_successfully" == true ] && [ "$container_state_paused" == true ] && Write-Log "DEBUG" "             => Container paused successfully"
    [ "$test_mode" == false ] && [ $result -ne 0 ] && [ "$new_container_started_successfully" == true ] && [ "$container_state_paused" == true ] && Write-Log "ERROR" "             => Failed to pause container: $result"
    
    # Collecting some informations for the report
    if [ "$new_container_started_successfully" == true ]; then
        mail_report_available=true
        [ "$test_mode" == false ] && [ "$update_type" == "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name ($image_name:$image_tag_old) has been preformed</li>"
        [ "$test_mode" == false ] && [ "$update_type" != "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name from $image_name:$image_tag_old to $image_name:$image_tag_new has been performed</li>"
        [ "$test_mode" == true ]  && [ "$update_type" == "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name ($image_name:$image_tag_old) would have been performed</li>"
        [ "$test_mode" == true ]  && [ "$update_type" != "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name from $image_name:$image_tag_old to $image_name:$image_tag_new would have been performed</li>"
    else
        mail_report_available=true
        [ "$test_mode" == false ] && [ "$update_type" == "digest" ] && mail_report_actions_taken+="<li>&#x1F534; A $update_type update for $container_name ($image_name:$image_tag_old) has failed <i>(please refer to your logs)</li>"
        [ "$test_mode" == false ] && [ "$update_type" != "digest" ] && mail_report_actions_taken+="<li>&#x1F534; A $update_type update for $container_name from $image_name:$image_tag_old to $image_name:$image_tag_new has failed <i>(please refer to your logs)</i></li>"
        [ "$test_mode" == true ]  && [ "$update_type" == "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name ($image_name:$image_tag_old) would have been performed</li>"
        [ "$test_mode" == true ]  && [ "$update_type" != "digest" ] && mail_report_actions_taken+="<li>&#x1F7E2; A $update_type update for $container_name from $image_name:$image_tag_old to $image_name:$image_tag_new would have been performed</li>"
    fi

    # Rolling back changes if update failed
    if [ "$test_mode" == false ] && [ "$new_container_started_successfully" == false ] && [ "$container_renamed_successfully" == true ]; then
        Write-Log "WARNING" "           Rolling back changes..."
        Write-Log "INFO"    "               Stopping new container ($container_name)..."
        { $cmd_docker stop $container_name > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "                 => Successfully stopped container"
        [ $result -ne 0 ] && Write-Log "ERROR" "                 => Failed to stop container" && ((this_errors_count+=1))
        Write-Log "INFO"    "               Removing new container ($container_name)..."
        { $cmd_docker rm -fv $container_name > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "                 => Successfully removed container"
        [ $result -ne 0 ] && Write-Log "ERROR" "                 => Failed to remove container" && ((this_errors_count+=1))
        Write-Log "INFO"    "               Restoring start up policy for old container ($container_name_backed_up)..."
        { $cmd_docker update $container_name_backed_up --restart $container_restartPolicy_name > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "                 => Successfully updated start up policy"
        [ $result -ne 0 ] && Write-Log "ERROR" "                 => Failed to update startup policy" && ((this_errors_count+=1))
        Write-Log "INFO"    "               Renaming old docker container from $container_name_backed_up to $container_name..."
        { $cmd_docker rename $container_name_backed_up $container_name > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "                 => Successfully to rename container"
        [ $result -ne 0 ] && Write-Log "ERROR" "                 => Failed to rename container" && ((this_errors_count+=1))
        Write-Log "INFO"    "               Starting old container ($container_name)..."
        { $cmd_docker start $container_name > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "                 => Successfully started container"
        [ $result -ne 0 ] && Write-Log "ERROR" "                 => Failed to start container" && ((this_errors_count+=1))

        if [ "$this_errors_count" -eq 0 ]; then
            mail_report_actions_taken+="<ul><li>&#x1F7E2; The original container $container_name ($image_name:$image_tag_old) has been successfully restored</li></ul>"
        else
            mail_report_actions_taken+="<ul><li>&#x1F7E1; A partly successfull attempt was made to restore the original container $container_name ($image_name:$image_tag_old) <i>(please refer to your logs)</i></li></ul>"
        fi
        this_errors_count=0
    fi

    Write-Log "INFO" "       Update processed"
}

Prune-ContainerBackups() {
    local prune_container_backups=$(Read-INI "$configFile" "general" "prune_container_backups")
    local container_backups_retention=$(Read-INI "$configFile" "general" "container_backups_retention")
    local container_backups_keep_last=$(Read-INI "$configFile" "general" "container_backups_keep_last")
    local cmd_docker=$(Read-INI "$configFile" "paths" "docker")
    local container_name_original=""
    local container_backup_date=""
    local container_backup_count=""

    if [ "$prune_container_backups" == true ]; then
        $cmd_docker ps -a --format "{{.Names}}" | sort | while read -r container_name; do
            if [[ "$container_name" == *_bak_* && -z "$($cmd_docker ps -q -f name=$container_name)" ]]; then
                Write-Log "DEBUG" "    Processing container \"$container_name\""
                
                container_name_original=$(echo $container_name | sed 's/_bak_.*//')
                container_backup_date=$(echo $container_name | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
                container_backup_count=$($cmd_docker ps -a --filter "name=^${container_name_original}_bak_" --filter "status=exited" --format '{{.Names}}' | wc -l)

                Write-Log "DEBUG" "        Container Information"
                Write-Log "DEBUG" "            Original Container Name: $container_name_original"
                Write-Log "DEBUG" "            Backup Date:             $container_backup_date"
                Write-Log "DEBUG" "            Available Backups:       $container_backup_count"

                if [[ "$container_backup_date" != "" && "$container_backup_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$container_backup_count" -gt $container_backups_keep_last ]]; then
                    backup_timestamp=$(date -d "$container_backup_date" +%s)
                    current_timestamp=$(date +%s)
                    days_diff=$(( (current_timestamp - backup_timestamp) / 86400 ))
                    if [ $days_diff -ge $container_backups_retention ]; then
                        Write-Log "INFO" "        Removing backed up container $container_name..."
                        { $cmd_docker rm -fv $container_name > /dev/null; result=$?; } || result=$?
                        [ $result -eq 0 ] && Write-Log "DEBUG" "          => Successfully removed container" && mail_report_removed_container_backups+="<li>$container_name</li>"
                        [ $result -ne 0 ] && Write-Log "ERROR" "          => Failed to remove container: $result"

                    else
                        Write-Log "DEBUG" "        The removal of this container backup is skipped as it is less than $container_backups_retention days old"
                    fi
                else
                    if [[ "$container_backup_date" == "" ]]; then
                        Write-Log "ERROR" "        No backup date found in containers name"
                    elif ! [[ "$container_backup_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                        Write-Log "ERROR" "        Backup date given in containers name is invalid. ($container_backup_date)"
                    elif ! [[ "$container_backup_count" -gt 1 ]]; then
                        Write-Log "DEBUG" "        Removing this container backup is prohibited due to the policy in your configuration file"
                    fi
                fi
            fi
        done
    fi
}

Prune-DockerImages() {
    local prune_images=$(Read-INI "$configFile" "general" "prune_images")
    local cmd_docker=$(Read-INI "$configFile" "paths" "docker")

    if [ "$prune_images" == true ]; then
        Write-Log "INFO" "    Pruning docker images..."
        { $cmd_docker image prune -af > /dev/null; result=$?; } || result=$?
        [ $result -eq 0 ] && Write-Log "DEBUG" "      => Successfully pruned images"
        [ $result -ne 0 ] && Write-Log "ERROR" "      => Failed to prune images: $result"
    fi
}

Send-MailNotification() {
    local test_mode=$(Read-INI "$configFile" "general" "test_mode")
    local logFile=$(Read-INI "$configFile" "log" "filePath")
    local mail_mode=$(Read-INI "$configFile" "mail" "mode")
    local mail_from=$(Read-INI "$configFile" "mail" "from")
    local mail_recipients=$(Read-INI "$configFile" "mail" "recipients")
    local mail_subject=$(Read-INI "$configFile" "mail" "subject")
    local cmd_sendmail=$(Read-INI "$configFile" "paths" "sendmail")
    local cmd_cut=$(Read-INI "$configFile" "paths" "cut")
    local mail_message=""
    local mail_message_file="$(mktemp)"
    local hostname=$(hostname)
    local primary_IPaddress=$(hostname -I 2>/dev/null | $cmd_cut -d' ' -f1)
    local docker_version=$(docker --version | $cmd_cut -d ' ' -f3 | tr -d ',')
    local end_time=$(date +%s)
    stats_execution_time=$((end_time - start_time))

    if [[ "$mail_report_available" == true && -n "$mail_from" && -n "$mail_recipients" && -n "$mail_subject" ]]; then

        end_time=$(date +%s)
        duration=$((end_time - start_time))

        for mail_recipient in $mail_recipients; do
            Write-Log "INFO" "    Generating mail report for recipient \"$mail_recipient\"..."
        
            mail_message="From: $mail_from\n"
            mail_message+="To: $mail_recipient\n"
            mail_message+="Subject: $mail_subject\n"
            mail_message+="MIME-Version: 1.0\n"
            mail_message+="Content-Type: text/html; charset=UTF-8\n"
            mail_message+="\n"
            mail_message+="<html>\n"
                mail_message+="<body>\n"
                    mail_message+="<p>Ahoi Captain,</p>\n"
                    mail_message+="<p> </p>\n"
                    mail_message+="<p>this email is to notify you of recent changes and available updates for your Docker containers.</p>\n"
                    mail_message+="<p> </p>\n"
                    mail_message+="<div style=\"border: 2px solid #ccc; padding: 0 15px;\">\n"
                        mail_message+="<table border="0" style=\"font-size: 25px;\">"
                        mail_message+="<tr>"
                            mail_message+="<td style=\"font-size: 50px;\">&#x1F433;</td>"
                            mail_message+="<td style=\"padding: 30px 15px; color: #4b4b4b;\"><strong>Docker Container Update Report</strong></td>"
                        mail_message+="</tr>"
                        mail_message+="</table>"

                        mail_message+="<p style=\"font-size: 14px; padding: 0px 5px; color: #4b4b4b;\"><strong>&#x1F4CC; INFO</strong></p>\n"
                        if [ "$test_mode" == true ]; then
                            mail_message+="<p style=\"font-size: 13px; padding: 0 30px; color: darkgreen;\"><strong>TEST MODE ENABLED</strong> <br> To disable test mode, please customize \"$configFile\".</p>\n"
                        fi
                        mail_message+="<table border="0" style=\"font-size: 13px; padding: 0 30px;\">"
                            mail_message+="<tr>"
                                mail_message+="<td>Hostname:</td>"
                                mail_message+="<td>$hostname</td>"
                            mail_message+="</tr>"
                            mail_message+="<tr>"
                                mail_message+="<td>IP-Address:</td>"
                                mail_message+="<td>$primary_IPaddress</td>"
                            mail_message+="</tr>"
                            mail_message+="<tr>"
                                mail_message+="<td>Docker Version:</td>"
                                mail_message+="<td>$docker_version</td>"
                            mail_message+="</tr>"
                            mail_message+="<tr>"
                                mail_message+="<td>Script Version:</td>"
                                mail_message+="<td>$(Get-ScriptVersion)</td>"
                            mail_message+="</tr>"
                        mail_message+="</table>"
                        mail_message+="\n"

                        if [ -n "$mail_report_actions_taken" ]; then
                            mail_message+="<p style=\"font-size: 14px; padding-top: 15px; padding-left: 5px; color: #4b4b4b;\"><strong>&#x1F4CB; ACTIONS TAKEN</strong></p>\n"
                            mail_message+="<ul style=\"font-size: 13px; padding: 0px 50px;\">"
                                mail_message+="$mail_report_actions_taken"
                            mail_message+="</ul>"
                            mail_message+="\n"
                        fi

                        if [ -n "$mail_report_available_updates" ]; then
                            mail_message+="<p style=\"font-size: 14px; padding-top: 15px; padding-left: 5px; color: #4b4b4b;\"><strong>&#x1F527; AVAILABLE UPDATES FOR MANUAL INSTALLATION</strong></p>\n"
                            mail_message+="<table border="0" style=\"font-size: 13px; padding: 0 30px 15px;\">"
                                mail_message+="<tr>"
                                    mail_message+="<td><strong>Container Name</strong></td>"
                                    mail_message+="<td><strong>Update Type</strong></td>"
                                    mail_message+="<td><strong>Current Image</strong></td>"
                                    mail_message+="<td><strong>Available Image</strong></td>"
                                    mail_message+="<td><strong>Update Inhibitor Rule</strong></td>"
                                    mail_message+="$mail_report_available_updates"
                                mail_message+="</tr>"
                            mail_message+="</table>"
                        fi

                        if [ -n "$mail_report_removed_container_backups" ]; then
                            mail_message+="<p style=\"font-size: 14px; padding-top: 15px; padding-left: 5px; color: #4b4b4b;\"><strong>&#128465;&#65039; REMOVED CONTAINER BACKUPS</strong></p>\n"
                            mail_message+="<ul style=\"font-size: 13px; padding: 0px 30px;\">"
                                mail_message+="$mail_report_removed_container_backups"
                            mail_message+="</ul>"
                            mail_message+="\n"
                        fi

                        mail_message+="<p style=\"font-size: 14px; padding-top: 15px; padding-left: 5px; color: #4b4b4b;\"><strong>&#x1F4C8; STATS</strong></p>\n"
                        mail_message+="<table border="0" style=\"font-size: 13px; padding: 0 30px 15px;\">"
                            mail_message+="<tr>"
                                mail_message+="<td>Script Execution Time:</td>"
                                mail_message+="<td>$stats_execution_time seconds</td>"
                            mail_message+="</tr>"
                            mail_message+="<tr>"
                                mail_message+="<td>Number of Warnings:</td>"
                                mail_message+="<td>$stats_warnings_count</td>"
                            mail_message+="</tr>"
                            mail_message+="<tr>"
                                mail_message+="<td>Number of Errors:</td>"
                                mail_message+="<td>$stats_errors_count</td>"
                            mail_message+="</tr>"
                        mail_message+="</table>"
                        mail_message+="\n"

                    mail_message+="</div>\n"
                    mail_message+="<p> </p>\n"
                    mail_message+="\n"
                    mail_message+="<p style=\"font-size: 10px;\"><i>For further information, please have a look into the provided log located in \"$logFile\". If you prefer not to receive these emails, please customize \"$configFile\" according to your specific requirements.</i></p>"
                    mail_message+="<p> </p>\n"
                    mail_message+="<p>Best regards.</p>"
                    mail_message+="\n"
                mail_message+="</body>\n"
            mail_message+="</html>\n"

            Write-Log "INFO" "        Saving generated mail report to \"$mail_message_file\"..."
                echo -e $mail_message > "$mail_message_file" || Write-Log "ERROR" "        Failed to create temporary mail message file (\"$mail_message_file\")"
                
            Write-Log "INFO" "        Sending notification via $mail_mode (\"$cmd_sendmail -t < $mail_message_file\")..."
                $cmd_sendmail -t < "$mail_message_file"  2>/dev/null

            Write-Log "INFO" "        Removing temporary mail message file (\"$mail_message_file\")..."
                rm -f "$mail_message_file" 2>/dev/null || Write-Log "ERROR" "        Failed to delete temporary mail message file (\"$mail_message_file\")"
        done
    else
        Write-Log "INFO" "        There is nothing to report"
    fi
}

Main() {
    Acquire-Lock
    Validate-ConfigFile
    Test-Prerequisites

    Write-Log "INFO" "Retrieving a list of currently running or paused docker containers and it's properties..."

    local test_mode=$(Read-INI "$configFile" "general" "test_mode")
    local mail_notifications_enabled=$(Read-INI "$configFile" "mail" "notifications_enabled")
    local cmd_sed=$(Read-INI "$configFile" "paths" "sed")
    local cmd_jq=$(Read-INI "$configFile" "paths" "jq")
    local cmd_docker=$(Read-INI "$configFile" "paths" "docker")
    local container_ids=($($cmd_docker ps -q))
    local container_id=""
    local container_config=""
    local container_name=""
    local container_hostname=""
    local container_state_paused=""
    local container_hostname=""
    local container_labels=""
    local container_labels_unique=""
    local container_capabilities=""
    local container_networkMode=""
    local container_networkMode_IPv4Address=""
    local container_networkMode_IPv6Address=""
    local container_networkMode_MacAddress=""
    local container_primaryNetwork_Name=""
    local container_primaryNetwork_IPv4Address=""
    local container_primaryNetwork_IPv6Address=""
    local container_primaryNetwork_MacAddress=""
    local container_restartPolicy_name=""
    local container_restartPolicy_MaximumRetryCount=""
    local container_PublishAllPorts=""
    local container_PortBindings=""
    local container_Mounts=""
    local container_envs=""
    local container_envs_unique=""
    local container_tmpfs=""
    local container_cmd=""
    local container_image_id=""
    local container_image_name=""
    local container_image_tag=""
    local container_hostname=""
    local image_config=""
    local image_labels=""
    local image_envs=""
    local image_cmd=""
    local image_repoDigests=""
    local effective_update_rule=""
    local docker_hub_image_url=""
    local docker_hub_image_tags=""
    local docker_hub_image_tag_names=""
    local docker_hub_image_tag_names_filter=""
    local docker_hub_image_tag_names_filtered=""
    local docker_hub_image_tag_names_filtered_and_sorted=""
    local docker_hub_image_tag_names_filtered_and_sorted_by_major=""
    local docker_hub_image_tag_names_filtered_and_sorted_by_minor=""
    local docker_hub_image_tag_names_filtered_and_sorted_by_patch=""
    local docker_hub_image_tag_names_filtered_and_sorted_by_build=""
    local docker_hub_image_tag_digest=""
    local image_updates_available_all=""
    local image_update_available_major_next=""
    local image_update_available_minor_next=""
    local image_update_available_patch_next=""
    local image_update_available_build_next=""
    local image_update_available_major_latest=""
    local image_update_available_minor_latest=""
    local image_update_available_patch_latest=""
    local image_update_available_build_latest=""
    local image_update_available_digest=""
    local updatePermit=""


    if [ ${#container_ids[@]} -gt 0 ]; then
        for container_id in "${container_ids[@]}"; do
            container_name=""
            container_hostname=""
            container_state_paused=""
            container_labels=""
            container_labels_unique=""
            container_capabilities=""
            container_networkMode=""
            container_networkMode_IPv4Address=""
            container_networkMode_IPv6Address=""
            container_networkMode_MacAddress=""
            container_primaryNetwork_Name=""
            container_primaryNetwork_IPv4Address=""
            container_primaryNetwork_IPv6Address=""
            container_primaryNetwork_MacAddress=""
            container_restartPolicy_name=""
            container_restartPolicy_MaximumRetryCount=""
            container_PublishAllPorts=""
            container_PortBindings=""
            container_Mounts=""
            container_envs=""
            container_envs_unique=""
            container_tmpfs=""
            container_cmd=""
            container_image_name=""
            container_image_id=""
            image_labels=""
            image_envs=""
            image_cmd=""
            container_image_tag=""
            image_tag_version_major=""
            image_tag_version_minor=""
            image_tag_version_patch=""
            image_tag_version_build=""
            image_repoDigests=""
            docker_hub_image_url=""
            container_config=""
            image_config=""
            docker_hub_image_tags=""
            docker_hub_image_tag_digest=""
            docker_hub_image_tag_names_filter=""
            docker_hub_image_tag_names=""
            effective_update_rule=""
            image_updates_available_all=""
            image_update_available_digest=false
            image_update_available_build_next=""
            image_update_available_patch_next=""
            image_update_available_minor_next=""
            image_update_available_major_next=""
            image_update_available_build_latest=""
            image_update_available_patch_latest=""
            image_update_available_minor_latest=""
            image_update_available_major_latest=""
            updatePermit=false

            Write-Log "INFO" "<print_line>"
            Write-Log "INFO" " | PROCESSING CONTAINER $container_id"
            Write-Log "INFO" "<print_line>"
            Write-Log "INFO" "    Requesting container configuration by executing \"$cmd_docker container inspect "$container_id"\"..."
            container_config=$(echo $($cmd_docker container inspect "$container_id") | tr -d '\n') #json
            container_image_id=$(Get-ContainerProperty "$container_config" container_image_id)
            Write-Log "INFO" "    Requesting image details by executing \"$cmd_docker image inspect $container_image_id\"..."
            image_config=$(echo $($cmd_docker image inspect $container_image_id) | tr -d '\n') #json
            docker_run_command_creation_completed=false
            container_name=$(Get-ContainerProperty "$container_config" container_name)
            container_hostname=$(Get-ContainerProperty "$container_config" container_hostname)
            container_state_paused=$(Get-ContainerProperty "$container_config" container_state_paused)
            container_labels=$(Get-ContainerProperty "$container_config" container_labels)
            container_capabilities=$(Get-ContainerProperty "$container_config" container_capabilities)
            container_networkMode=$(Get-ContainerProperty "$container_config" container_networkMode)
            container_networkMode_IPv4Address=$(Get-ContainerProperty "$container_config" container_networkMode_IPv4Address)
            container_networkMode_IPv6Address=$(Get-ContainerProperty "$container_config" container_networkMode_IPv6Address)
            container_networkMode_MacAddress=$(Get-ContainerProperty "$container_config" container_networkMode_MacAddress)
            container_primaryNetwork_Name=$(Get-ContainerProperty "$container_config" container_primaryNetwork_Name)
            container_primaryNetwork_IPv4Address=$(Get-ContainerProperty "$container_config" container_primaryNetwork_IPv4Address)
            container_primaryNetwork_IPv6Address=$(Get-ContainerProperty "$container_config" container_primaryNetwork_IPv6Address)
            container_primaryNetwork_MacAddress=$(Get-ContainerProperty "$container_config" container_primaryNetwork_MacAddress)
            container_restartPolicy_name=$(Get-ContainerProperty "$container_config" container_restartPolicy_name)
            container_restartPolicy_MaximumRetryCount=$(Get-ContainerProperty "$container_config" container_restartPolicy_MaximumRetryCount)
            container_PublishAllPorts=$(Get-ContainerProperty "$container_config" container_PublishAllPorts)
            container_PortBindings=$(Get-ContainerProperty "$container_config" container_PortBindings)
            container_Mounts=$(Get-ContainerProperty "$container_config" container_Mounts)
            container_Mounts_prtyprnt=$(Get-ContainerProperty "$container_config" container_Mounts | $cmd_sed '0,/^\s*--mount \s*/ s///' | $cmd_sed "s#--mount #\n[$(date +%Y/%m/%d\ %H:%M:%S)] DEBUG                                                #g")
            container_envs=$(Get-ContainerProperty "$container_config" container_envs)
            container_tmpfs=$(Get-ContainerProperty "$container_config" container_tmpfs)
            container_cmd=$(Get-ContainerProperty "$container_config" container_cmd)
            container_image_name=$(Get-ContainerProperty "$container_config" container_image_name)
            container_image_tag=$(Get-ContainerProperty "$container_config" container_image_tag)
            image_repoDigests=$(Get-ImageProperty "$image_config" image_repoDigests)
            image_labels=$(Get-ImageProperty "$image_config" image_labels)
            image_envs=$(Get-ImageProperty "$image_config" image_envs)
            image_cmd=$(Get-ImageProperty "$image_config" image_cmd)
            image_tag_version_major=$(Extract-VersionPart "$container_image_tag" "major")
            image_tag_version_minor=$(Extract-VersionPart "$container_image_tag" "minor")
            image_tag_version_patch=$(Extract-VersionPart "$container_image_tag" "patch")
            image_tag_version_build=$(Extract-VersionPart "$container_image_tag" "build")
            effective_update_rule=$(Get-EffectiveUpdateRule "$container_name")
            container_labels_unique=$(Get-ContainerPropertyUnique "$container_labels" "$image_labels" "unique_labels")
            container_envs_unique=$(Get-ContainerPropertyUnique "$container_envs" "$image_envs" "unique_envs")
            docker_hub_image_url=$(Get-DockerHubImageURL "$container_image_name")
            docker_hub_image_tag_names_filter=$(New-DockerHubImageTagFilter "$container_image_tag")
            
            # To be able to report available and outstanding updates for containers/images, this if-statement ist commented out 
            #if [[ ! $effective_update_rule == *"[0.0.0-0,false]"* ]]; then
            Write-Log "INFO"  "    Requesting available image tags from Docker Hub..."
            docker_hub_image_tags=$(Get-DockerHubImageTags "$container_image_name") #json
            [ -z "$docker_hub_image_tags" ] && Write-Log "ERROR" "    => Failed to request available image tags: wget $docker_hub_image_url/tags"
            #else
            #    Write-Log "INFO"  "    Request of available image tags from Docker Hub is restricted by specified update rule \"$effective_update_rule\""
            #    docker_hub_image_tags=""
            #fi

            if [ -n "$docker_hub_image_tags" ]; then
                Write-Log "INFO"  "    Extracting a list of available image tag names..."
                docker_hub_image_tag_digest=$(Get-DockerHubImageTagProperty "$docker_hub_image_tags" "$container_image_tag" "docker_hub_image_tag_digest")
                docker_hub_image_tag_names=$(Get-DockerHubImageTagNames "$docker_hub_image_tags")
                image_updates_available_all=$(Get-AvailableUpdates "all" "$docker_hub_image_tag_names" "$docker_hub_image_tag_names_filter" "$container_image_tag")
                [ -n "$docker_hub_image_tag_digest" ] && image_update_available_digest=$(Get-AvailableUpdates "digest" "$image_repoDigests" "$docker_hub_image_tag_digest")
                [ -n "$image_tag_version_major" ] && image_update_available_major_next=$(Get-AvailableUpdates "major" "$image_updates_available_all" "$container_image_tag" "next")
                [ -n "$image_tag_version_major" ] && image_update_available_major_latest=$(Get-AvailableUpdates "major" "$image_updates_available_all" "$container_image_tag" "latest")
                [ -n "$image_tag_version_minor" ] && image_update_available_minor_next=$(Get-AvailableUpdates "minor" "$image_updates_available_all" "$container_image_tag" "next")
                [ -n "$image_tag_version_minor" ] && image_update_available_minor_latest=$(Get-AvailableUpdates "minor" "$image_updates_available_all" "$container_image_tag" "latest")
                [ -n "$image_tag_version_patch" ] && image_update_available_patch_next=$(Get-AvailableUpdates "patch" "$image_updates_available_all" "$container_image_tag" "next")
                [ -n "$image_tag_version_patch" ] && image_update_available_patch_latest=$(Get-AvailableUpdates "patch" "$image_updates_available_all" "$container_image_tag" "latest")
                [ -n "$image_tag_version_build" ] && image_update_available_build_next=$(Get-AvailableUpdates "build" "$image_updates_available_all" "$container_image_tag" "next")
                [ -n "$image_tag_version_build" ] && image_update_available_build_latest=$(Get-AvailableUpdates "build" "$image_updates_available_all" "$container_image_tag" "latest")
            elif [ -z "$docker_hub_image_tags" ] || [[ $effective_update_rule == *"[0.0.0-0,false]"* ]]; then 
                docker_hub_image_tag_digest=""
                docker_hub_image_tag_names=""
                image_update_available_major_next=""
                image_update_available_major_latest=""
                image_update_available_minor_next=""
                image_update_available_minor_latest=""
                image_update_available_patch_next=""
                image_update_available_patch_latest=""
                image_update_available_build_next=""
                image_update_available_build_latest=""
                image_update_available_digest=""
            fi

            Write-Log "INFO"  "    <print_line>"
            Write-Log "INFO"  "    | CONTAINER AND IMAGE DETAILS"
            Write-Log "INFO"  "    <print_line>"
            Write-Log "INFO"  "       Container Name:                                       $container_name"
            Write-Log "DEBUG" "       Container Hostname:                                   $container_hostname"
            Write-Log "DEBUG" "       Container Is Paused:                                  $container_state_paused"
            Write-Log "DEBUG" "       Container ID:                                         $container_id"
            Write-Log "DEBUG" "       Container Labels:                                     $container_labels"
            Write-Log "DEBUG" "       Container Labels (Unique):                            $container_labels_unique"
            Write-Log "DEBUG" "       Container Capabilities:                               $container_capabilities"
            Write-Log "DEBUG" "       Container Network Mode:                               $container_networkMode"
            Write-Log "DEBUG" "       Container Primary Network Name:                       $container_primaryNetwork_Name"
            Write-Log "DEBUG" "       Container Primary IPv4-Address:                       $container_primaryNetwork_IPv4Address"
            Write-Log "DEBUG" "       Container Primary IPv6-Address:                       $container_primaryNetwork_IPv6Address"
            Write-Log "DEBUG" "       Container Primary MAC-Address:                        $container_primaryNetwork_MacAddress"
            Write-Log "DEBUG" "       Container Network Mode IPv4-Address:                  $container_networkMode_IPv4Address"
            Write-Log "DEBUG" "       Container Network Mode IPv6-Address:                  $container_networkMode_IPv6Address"
            Write-Log "DEBUG" "       Container Network Mode MAC-Address:                   $container_networkMode_MacAddress"
            Write-Log "DEBUG" "       Container Restart Policy Name:                        $container_restartPolicy_name"
            Write-Log "DEBUG" "       Container Maximum Retry Count:                        $container_restartPolicy_MaximumRetryCount"
            Write-Log "DEBUG" "       Container Publish All Ports:                          $container_PublishAllPorts"
            Write-Log "DEBUG" "       Container Port Bindings:                              $container_PortBindings"
            Write-Log "DEBUG" "       Container Mounts:                                     $container_Mounts"
            Write-Log "DEBUG" "       Container Environment Variables:                      $container_envs"
            Write-Log "DEBUG" "       Container Environment Variables (Unique):             $container_envs_unique"
            Write-Log "DEBUG" "       Container Temporary File Systems:                     $container_tmpfs"
            Write-Log "DEBUG" "       Container Command:                                    $container_cmd"
            Write-Log "INFO"  "       Image Name:                                           $container_image_name"
            Write-Log "DEBUG" "       Image ID:                                             $container_image_id"
            Write-Log "DEBUG" "       Image Labels:                                         $image_labels"
            Write-Log "DEBUG" "       Image Environment Variables:                          $image_envs"
            Write-Log "DEBUG" "       Image Command:                                        $image_cmd"
            Write-Log "INFO"  "       Image Tag:                                            $container_image_tag"
            Write-Log "DEBUG" "       Image Tag Ver. (Major):                               $image_tag_version_major"
            Write-Log "DEBUG" "       Image Tag Ver. (Minor):                               $image_tag_version_minor"
            Write-Log "DEBUG" "       Image Tag Ver. (Patch):                               $image_tag_version_patch"
            Write-Log "DEBUG" "       Image Tag Ver. (Build):                               $image_tag_version_build"
            Write-Log "DEBUG" "       Image Repository Digests:                             $image_repoDigests"
            Write-Log "INFO"  "       Image URL:                                            $docker_hub_image_url"
            #Write-Log "DEBUG" "       Container Details (json):                             $container_config"
            #Write-Log "DEBUG" "       Image Details (json):                                 $image_config"
            #[ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "       Docker Hub Image Tags (json):                         $docker_hub_image_tags"
            [ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "       Docker Hub Image Digest:                              $docker_hub_image_tag_digest"
            [ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "       Docker Hub Image Tag Filter:                          $docker_hub_image_tag_names_filter"
            #[ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "       Docker Hub Image Tag Names:                           $docker_hub_image_tag_names"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "       Update Overview:"
            [ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "             Effective Update Rule:                          $effective_update_rule"
            [ -n "$docker_hub_image_tags" ] && Write-Log "DEBUG" "             Listing (filtered & sorted):                    $image_updates_available_all"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             New Digest available:                           $image_update_available_digest"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Next Build:                                     $image_update_available_build_next"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Next Patch:                                     $image_update_available_patch_next"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Next Minor:                                     $image_update_available_minor_next"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Next Major:                                     $image_update_available_major_next"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Latest Build:                                   $image_update_available_build_latest"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Latest Patch:                                   $image_update_available_patch_latest"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Latest Minor:                                   $image_update_available_minor_latest"
            [ -n "$docker_hub_image_tags" ] && Write-Log "INFO"  "             Latest Major:                                   $image_update_available_major_latest"

            # Create docker run command (without specifying the image tag for the moment)
                                                                                                docker_run_cmd="$cmd_docker run -d"
            [ -n "$container_name" ] &&                                                         docker_run_cmd+=" --name=$container_name"
            [ -n "$container_hostname" ] &&                                                     docker_run_cmd+=" --hostname=$container_hostname"
            [ -n "$container_restartPolicy_name" ] &&                                           docker_run_cmd+=" --restart=$container_restartPolicy_name"
            [ -n "$container_networkMode" ] &&                                                  docker_run_cmd+=" --network=$container_networkMode"
            [ -n "$container_networkMode_IPv4Address" ] &&                                      docker_run_cmd+=" --ip=$container_networkMode_IPv4Address"
            [ -n "$container_networkMode_IPv6Address" ] &&                                      docker_run_cmd+=" --ip6=$container_networkMode_IPv6Address"
            [ -n "$container_PublishAllPorts" ] && [ "$container_PublishAllPorts" == true ] &&  docker_run_cmd+=" --publish-all"
            [ -n "$container_capabilities" ] &&                                                 docker_run_cmd+=" $container_capabilities"
            [ -n "$container_PortBindings" ] &&                                                 docker_run_cmd+=" $container_PortBindings"
            [ -n "$container_Mounts" ] &&                                                       docker_run_cmd+=" $container_Mounts"
            [ -n "$container_envs_unique" ] &&                                                  docker_run_cmd+=" $container_envs_unique"
            [ -n "$container_tmpfs" ] &&                                                        docker_run_cmd+=" $container_tmpfs"
            [ -n "$container_labels_unique" ] &&                                                docker_run_cmd+=" $container_labels_unique"
            [ -n "$container_image_name" ] &&                                                   docker_run_cmd+=" $container_image_name"

            # Perform a digest update if available and update permition is granted by update rule definition
            if [ -n "$container_name" ] && [ -n "$container_image_tag" ] && [ "$image_update_available_digest" == true ] && [ "$updatePermit" == false ]; then
                updatePermit=$(Get-UpdatePermit "$container_name" "$container_image_tag" "$container_image_tag")
                if [ "$updatePermit" == true ]; then
                    [ -n "$container_image_tag" ] &&    docker_run_cmd+=":$container_image_tag"
                    #[ -n "$container_cmd" ] &&          docker_run_cmd+=" $container_cmd"
                    Perform-ImageUpdate "digest" "$container_name" "$container_state_paused" "$container_restartPolicy_name" "$container_image_name" "$docker_run_cmd" "$container_image_tag"
                else
                    Write-Log "INFO" "       Update Rule Effectivity:                              Digest update for $container_name ($container_image_name:$container_image_tag) was prevented"
                    mail_report_available_updates+="<tr><td>$container_name</td><td>Digest</td><td>$container_image_name:$container_image_tag</td><td>$container_image_name:$container_image_tag</td><td>$effective_update_rule</td></tr>"
                fi
            fi

            # Perform a build update if available and update permition is granted by update rule definition
            if [ -n "$container_name" ] && [ -n "$container_image_tag" ] && [ -n "$image_update_available_build_next" ] && [ -n "$image_update_available_build_latest" ] && [ "$updatePermit" == false ]; then
                updatePermit=$(Get-UpdatePermit "$container_name" "$container_image_tag" "$image_update_available_patch_next" "$image_update_available_build_latest")
                if [ "$updatePermit" == true ]; then
                    [ -n "$container_image_tag" ] &&    docker_run_cmd+=":$image_update_available_build_next"
                    #[ -n "$container_cmd" ] &&          docker_run_cmd+=" $container_cmd"
                    Perform-ImageUpdate "build" "$container_name" "$container_state_paused" "$container_restartPolicy_name" "$container_image_name" "$docker_run_cmd" "$container_image_tag" "$image_update_available_build_next"
                else
                    Write-Log "INFO" "       Update Rule Effectivity:                              Build update for $container_name ($container_image_name:$container_image_tag to $container_image_name:$image_update_available_build_next) was prevented"
                    mail_report_available_updates+="<tr><td>$container_name</td><td>Build</td><td>$container_image_name:$container_image_tag</td><td>$container_image_name:$image_update_available_build_next</td><td>$effective_update_rule</td></tr>"
                fi
            fi

            # Perform a patch update if available and update permition is granted by update rule definition
            if [ -n "$container_name" ] && [ -n "$container_image_tag" ] && [ -n "$image_update_available_patch_next" ] && [ -n "$image_update_available_patch_latest" ] && [ "$updatePermit" == false ]; then
                updatePermit=$(Get-UpdatePermit "$container_name" "$container_image_tag" "$image_update_available_patch_next" "$image_update_available_patch_latest")
                if [ "$updatePermit" == true ]; then
                    [ -n "$container_image_tag" ] &&    docker_run_cmd+=":$image_update_available_patch_next"
                    #[ -n "$container_cmd" ] &&          docker_run_cmd+=" $container_cmd"
                    Perform-ImageUpdate "patch" "$container_name" "$container_state_paused" "$container_restartPolicy_name" "$container_image_name" "$docker_run_cmd" "$container_image_tag" "$image_update_available_patch_next"
                else
                    Write-Log "INFO" "       Update Rule Effectivity:                              Patch update for $container_name ($container_image_name:$container_image_tag to $container_image_name:$image_update_available_patch_next) was prevented"
                    mail_report_available_updates+="<tr><td>$container_name</td><td>Patch</td><td>$container_image_name:$container_image_tag</td><td>$container_image_name:$image_update_available_patch_next</td><td>$effective_update_rule</td></tr>"
                fi
            fi

            # Perform a minor update if available and update permition is granted by update rule definition
            if [ -n "$container_name" ] && [ -n "$container_image_tag" ] && [ -n "$image_update_available_minor_next" ] && [ -n "$image_update_available_minor_latest" ] && [ "$updatePermit" == false ]; then
                updatePermit=$(Get-UpdatePermit "$container_name" "$container_image_tag" "$image_update_available_minor_next" "$image_update_available_minor_latest")
                if [ "$updatePermit" == true ]; then
                    [ -n "$container_image_tag" ] &&    docker_run_cmd+=":$image_update_available_minor_next"
                    #[ -n "$container_cmd" ] &&          docker_run_cmd+=" $container_cmd"
                    Perform-ImageUpdate "minor" "$container_name" "$container_state_paused" "$container_restartPolicy_name" "$container_image_name" "$docker_run_cmd" "$container_image_tag" "$image_update_available_minor_next"
                else
                    Write-Log "INFO" "       Update Rule Effectivity:                              Minor update for $container_name ($container_image_name:$container_image_tag to $container_image_name:$image_update_available_minor_next) was prevented"
                    mail_report_available_updates+="<tr><td>$container_name</td><td>Minor</td><td>$container_image_name:$container_image_tag</td><td>$container_image_name:$image_update_available_minor_next</td><td>$effective_update_rule</td></tr>"
                fi
            fi

            # Perform a major update if available and update permition is granted by update rule definition
            if [ -n "$container_name" ] && [ -n "$container_image_tag" ] && [ -n "$image_update_available_major_next" ] && [ -n "$image_update_available_major_latest" ] && [ "$updatePermit" == false ]; then
                updatePermit=$(Get-UpdatePermit "$container_name" "$container_image_tag" "$image_update_available_major_next" "$image_update_available_major_latest")
                if [ "$updatePermit" == true ]; then
                    [ -n "$container_image_tag" ] &&    docker_run_cmd+=":$image_update_available_major_next"
                    #[ -n "$container_cmd" ] &&          docker_run_cmd+=" $container_cmd"
                    Perform-ImageUpdate "major" "$container_name" "$container_state_paused" "$container_restartPolicy_name" "$container_image_name" "$docker_run_cmd" "$container_image_tag" "$image_update_available_major_next"
                else
                    Write-Log "INFO" "       Update Rule Effectivity:                              Major update for $container_name ($container_image_name:$container_image_tag to $container_image_name:$image_update_available_major_next) was prevented"
                    mail_report_available_updates+="<tr><td>$container_name</td><td>Major</td><td>$container_image_name:$container_image_tag</td><td>$container_image_name:$image_update_available_major_next</td><td>$effective_update_rule</td></tr>"
                fi
            fi
        done

        if [ "$test_mode" == false ]; then
            Write-Log "INFO"  "<print_line>"
            Write-Log "INFO"  "| PRUNING PROGRESS"
            Write-Log "INFO"  "<print_line>"
            Prune-ContainerBackups
            Prune-DockerImages
        fi

        if [ "$mail_notifications_enabled" == true ]; then
            Write-Log "INFO" "<print_line>"
            Write-Log "INFO" " | MAIL NOTIFICATIONS"
            Write-Log "INFO" "<print_line>"
            Send-MailNotification
        fi
        
        Write-Log "INFO" "<print_line>"

        if [ "$test_mode" == true ]; then
            Write-Log "INFO" "Test mode is enabled in \"$configFile\". No changes have been made to your system."
        fi
    else
        Write-Log "ERROR" "No containers found"
    fi

    End-Script
}

Main