#!/bin/bash

# ==========================================
# Install Script Header (System Detection)
# ==========================================
PM=""
if command -v apk >/dev/null 2>&1; then
    PM="apk"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
elif command -v apt >/dev/null 2>&1; then
    PM="apt"
else
    echo "Unsupported system: no apt/dnf/yum/apk found."
    exit 1
fi

echo "[install-tcping] Package manager detected: $PM"

# ==========================================
# Check runtime deps
# ==========================================
required_tools=(bash date awk timeout getent)
missing_tools=()
for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing_tools+=("$t")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "Missing required dependencies: ${missing_tools[*]}"
    echo "Please install ${missing_tools[*]} first"
    exit 1
fi


echo "[install-tcping] Dependencies OK"

# ==========================================
# Generate /usr/bin/tcping
# ==========================================
INSTALL_PATH="/usr/bin/tcping"

echo "[install-tcping] Installing $INSTALL_PATH ..."

# Use 'EOF' (quoted) to prevent variable expansion during installation
cat << 'EOF' > "$INSTALL_PATH"
#!/bin/bash

# Defaults
FORCE_IPV4=0
FORCE_IPV6=0
COUNT=-1
HOST=""
PORT=""

# Error Handling / Usage
usage() {
cat <<END_USAGE
Usage: tcping [-4|-6] [-c times] host port
Options:
  -4        Use IPv4
  -6        Use IPv6
  -c N      Send N probes then stop
  -h        Show help
END_USAGE
}

error_missing_argument() {
    echo "Error: Missing required argument."
    usage
    exit 1
}

error_too_many_arguments() {
    echo "Error: Too many arguments."
    usage
    exit 1
}

error_invalid_option() {
    echo "Error: Invalid option."
    usage
    exit 1
}

error_option_requires_value() {
    echo "Error: Option requires a value."
    usage
    exit 1
}

error_invalid_count() {
    echo "Error: COUNT must be a number."
    usage
    exit 1
}

error_invalid() {
    echo "Error: Invalid argument(s)."
    usage
    exit 1
}

error_invalid_port() {
    echo "Error: Port must be a number."
    usage
    exit 1
}


# Parse Arguments
while getopts ":46c:h" opt; do
  case $opt in
    4) FORCE_IPV4=1 ;;
    6) FORCE_IPV6=1 ;;
    c)
       if [[ ! "$OPTARG" =~ ^[0-9]+$ ]]; then
           error_invalid_count
       fi
       COUNT="$OPTARG"
       ;;
    h) usage; exit 0 ;;
    \?) error_invalid_option ;;      
    :)  error_option_requires_value ;; 
  esac
done

if [ "$FORCE_IPV4" = "1" ] && [ "$FORCE_IPV6" = "1" ]; then
    echo "Error: Cannot specify both -4 and -6 at the same time."
    usage
    exit 1
fi

shift $((OPTIND-1))

# ============================
# Logic: Check Positional Args (Simplified Validation)
# ============================
if [ "$#" -lt 1 ] ; then
    error_missing_argument
fi

if [ "$#" -gt 2 ]; then
    error_too_many_arguments
fi

HOST=$1

# 1. Non-allowed Character Filter 
if [[ "$HOST" =~ [^A-Za-z0-9.:-] ]]; then
    error_invalid
fi

IS_IP=-1 

# 2. Check input format
if [[ "$HOST" == *"."* ]]; then
	if [[ "$HOST" == *[a-zA-Z]* ]]; then
		IS_IP=0
	else
		IS_IP=1
	fi
elif [[ "$HOST" = "localhost" ]]; then
    IS_IP=0
elif [[ "$HOST" == *":"* ]]; then
    IS_IP=1
else
    error_invalid
fi

# 3. Check input port

if [ "$#" -eq 2 ]; then 
    # Port is provided, perform validation
    PORT=$2
    # Port must be pure number and within 65535
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        error_invalid_port
    fi
fi

# ============================
# Logic: Resolve IP (Using getent for all non-strict IPv4)
# ============================
RESOLVED_IP=""

# 1. Fetch real IP form getent.
RESOLVE_CMD="getent ahosts $HOST"
    
if [ "$FORCE_IPV4" -eq 1 ]; then
    RESOLVED_IP=$($RESOLVE_CMD | awk '{ if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $1; exit } }')
elif [ "$FORCE_IPV6" -eq 1 ]; then
    RESOLVED_IP=$($RESOLVE_CMD | awk '{ if ($1 ~ /:/) { print $1; exit } }')
else
    RESOLVED_IP=$($RESOLVE_CMD | awk '{ print $1; exit }')
fi

# 2. Check for resolution failure 
if [ -z "$RESOLVED_IP" ]; then
    echo "Error: Failed to resolve address for $HOST"
    exit 1
fi

# 3. Assignment a default port if it missing
if [ "$#" -eq 1 ]; then
	if [ "$IS_IP" -ne 0 ] ; then
        PORT=22
        echo "Warning: Missing port. Using default port 22 for IP address."
    else
        PORT=443
        echo "Warning: Missing port. Using default port 443 for domain name."
    fi
fi

# 4. Determine display format for IP (add brackets for IPv6)
DISPLAY_IP="$RESOLVED_IP"
if [[ "$RESOLVED_IP" == *":"* ]]; then
    DISPLAY_IP="[$RESOLVED_IP]"
fi

# ============================
# Logic: Statistics Variables
# ============================
SENT=0
SUCCESS=0
FAILED=0
TOTAL_MS=0
MIN_MS=9999999.0
MAX_MS=0.0

# Clean up on Ctrl+C or Exit
print_stats() {
    # Avoid printing stats if we haven't started or only printed usage
    if [ "$SENT" -eq 0 ]; then exit 0; fi

    echo ""
    echo "Tcping statistics for $RESOLVED_IP:$PORT"
    
    # Calc fail rate
    if [ "$SENT" -gt 0 ]; then
        FAIL_RATE=$(awk -v f="$FAILED" -v s="$SENT" 'BEGIN { printf "%.2f", (f/s)*100 }')
    else
        FAIL_RATE="0.00"
    fi
    
    echo "     $SENT probes sent."
    echo "     $SUCCESS successful, $FAILED failed.  (${FAIL_RATE}% fail)"

    if [ "$SUCCESS" -gt 0 ]; then
        AVG_MS=$(awk -v t="$TOTAL_MS" -v s="$SUCCESS" 'BEGIN { printf "%.3f", t/s }')
        echo "Approximate trip times in milli-seconds:"
        echo "     Minimum = ${MIN_MS}ms, Maximum = ${MAX_MS}ms, Average = ${AVG_MS}ms"
    fi
}

trap print_stats EXIT

# ============================
# Logic: Header
# ============================
if [ "$IS_IP" -eq 0 ] ; then
	echo "Tcping $HOST ($RESOLVED_IP) port $PORT"
else
	echo "Tcping $HOST port $PORT"
fi
# ============================
# Logic: Main Loop
# ============================
while true; do
    # Check count limit
    if [ "$COUNT" -ne -1 ] && [ "$SENT" -ge "$COUNT" ]; then
        break
    fi

    ((SENT++))

    # Timestamp Start (Nanoseconds)
    START_TS=$(date +%s.%N)

    # Perform Connection (Timeout 2s)
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$RESOLVED_IP/$PORT" 2>/dev/null; then
        # Connection Success
        END_TS=$(date +%s.%N)
        
        # Calculate Duration in ms
        RTT_MS=$(awk -v s="$START_TS" -v e="$END_TS" 'BEGIN { printf "%.3f", (e-s)*1000 }')
        
        # Integer display for loop
        RTT_INT=$(printf "%.0f" "$RTT_MS")

        # Use DISPLAY_IP (with brackets for IPv6) here
        echo "Probing $DISPLAY_IP:$PORT  time=${RTT_INT}ms"

        # Update Stats
        ((SUCCESS++))
        TOTAL_MS=$(awk -v t="$TOTAL_MS" -v r="$RTT_MS" 'BEGIN { print t+r }')
        
        # Min/Max
        if (( $(awk -v r="$RTT_MS" -v m="$MIN_MS" 'BEGIN { print (r<m) ? 1 : 0 }') )); then
            MIN_MS=$RTT_MS
        fi
        if (( $(awk -v r="$RTT_MS" -v m="$MAX_MS" 'BEGIN { print (r>m) ? 1 : 0 }') )); then
            MAX_MS=$RTT_MS
        fi

        sleep 1
    else
        # Connection Failed
        ((FAILED++))
        echo "Probing $DISPLAY_IP:$PORT  No response"
        sleep 1
    fi
done

EOF

# ==========================================
# Post Install
# ==========================================
chmod +x "$INSTALL_PATH"
echo "[install-tcping] Done!"
