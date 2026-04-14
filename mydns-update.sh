#!/bin/bash

# --- Load Configuration ---
CONF_FILE="/etc/mydns/mydns.conf"
[[ ! -f "$CONF_FILE" ]] && echo "Error: $CONF_FILE not found." >&2 && exit 1
source "$CONF_FILE"

# Prepare cache directory
mkdir -p "$CACHE_DIR"

log_message() {
    local target_log="${LOG_FILE:-/var/log/mydns_update.log}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$target_log"
}

# Function to fetch current global IP address
get_current_ip() {
    local url=$1
    curl -s -m "$TIMEOUT" --connect-timeout "$CONN_TIMEOUT" "$url" | tr -d '[:space:]'
}

update_dns() {
    local cred=$1
    local url=$2
    local mode=$3
    local current_ip=$4
    local id_only="${cred%%:*}"
    local cache_file="${CACHE_DIR}/${id_only}_${mode}.lastip"
    local force_update="no"

    # --- Update Determination Logic ---
    
    # 1. Force update if cache does not exist (Initial execution)
    if [[ ! -f "$cache_file" ]]; then
        force_update="yes"
        local reason="Initial execution"
    else
        local last_ip=$(cat "$cache_file")
        
        # 2. Force update if IP has changed
        if [[ "$current_ip" != "$last_ip" ]]; then
            force_update="yes"
            local reason="IP changed (${last_ip} -> ${current_ip})"
        
        # 3. Force update if 24 hours have passed even without IP change
        # find -mmin +1440 checks if the file was modified more than 1440 minutes (24h) ago
        elif [[ -n $(find "$cache_file" -mmin +1440) ]]; then
            force_update="yes"
            local reason="24 hours elapsed since last update"
        fi
    fi

    # Exit if no update is required
    if [[ "$force_update" == "no" ]]; then
        return 0
    fi

    # --- Execute Update ---
    response=$(curl -s -u "${cred}" -A "${USER_AGENT}" -m "${TIMEOUT}" \
        --connect-timeout "${CONN_TIMEOUT}" --fail --globoff "$url" 2>&1)
    
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_message "[$mode] Success: $reason. ID $id_only updated."
        # Update cache file (using touch to refresh mtime even if IP is identical)
        echo "$current_ip" > "$cache_file"
        touch "$cache_file"
    elif [[ $exit_code -eq 22 ]]; then
        log_message "[$mode] Auth Error (401): ID $id_only."
    else
        log_message "[$mode] Error (Code: $exit_code): ID $id_only. Reason: $reason"
    fi
}

# --- Main Process ---

# 1. Fetch current global IP addresses
[[ "$ENABLE_IPV4" == "yes" ]] && CURRENT_IPV4=$(get_current_ip "$CHECK_IPV4_URL")
[[ "$ENABLE_IPV6" == "yes" ]] && CURRENT_IPV6=$(get_current_ip "$CHECK_IPV6_URL")

# 2. Iterate through credentials and execute updates
for entry in "${MYDNS_CREDENTIALS[@]}"; do
    if [[ "$ENABLE_IPV4" == "yes" && -n "$CURRENT_IPV4" ]]; then
        update_dns "$entry" "$IPV4_URL" "IPv4" "$CURRENT_IPV4"
    fi

    if [[ "$ENABLE_IPV6" == "yes" && -n "$CURRENT_IPV6" ]]; then
        update_dns "$entry" "$IPV6_URL" "IPv6" "$CURRENT_IPV6"
    fi
done

exit 0
