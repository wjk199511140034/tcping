#!/bin/bash

# ==========================================
# Install Script Header (System Detection)
# ==========================================
PM=""
if command -v apt >/dev/null 2>&1; then
    PM="apt"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
elif command -v apk >/dev/null 2>&1; then
    PM="apk"
else
    echo "Unsupported system: no apt/dnf/yum/apk found."
    exit 1
fi

echo "[install-tcping] Package manager detected: $PM"

# ==========================================
# Check runtime deps
# ==========================================
required_tools=(bash date awk timeout)
missing_tools=()
for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing_tools+=("$t")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "Missing required tools: ${missing_tools[*]}"
    echo "Please install ${missing_tools[*]} first"
    exit 1
fi

echo "[install-tcping] Dependencies OK"

# ==========================================
# Generate /usr/bin/tcping
# ==========================================
INSTALL_PATH="/usr/bin/tcping"

echo "[install-tcping] Installing $INSTALL_PATH ..."

# We use 'EOF' (quoted) to prevent variable expansion during installation
cat << 'EOF' > "$INSTALL_PATH"
#!/bin/bash

# Defaults
FORCE_IPV4=0
FORCE_IPV6=0
COUNT=-1
HOST=""
PORT=""

# Regex helpers
IPV4_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
# Note: IPV6_REGEX check is simplified by checking for ':' later.

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

exit_error() {
    echo "Error: Wrong argument"
    usage
    exit 1
}

# Parse Arguments
while getopts ":46c:h" opt; do
  case $opt in
    4) FORCE_IPV4=1 ;;
    6) FORCE_IPV6=1 ;;
    c) 
       if [[ ! "$OPTARG" =~ ^[0-9]+$ ]]; then exit_error; fi
       COUNT="$OPTARG" 
       ;;
    h) usage; exit 0 ;;
    \?) exit_error ;; # Invalid option
    :) exit_error ;;  # Missing argument
  esac
done
shift $((OPTIND-1))

# ============================
# Logic: Check Positional Args
# ============================
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    exit_error
fi

HOST=$1

if [ "$#" -eq 1 ]; then
    # Missing Port Logic: Determine if HOST is IP or Domain
    
    IS_IP=0
    # Check for IPv4
    if [[ "$HOST" =~ $IPV4_REGEX ]]; then
        IS_IP=1
    # Check for IPv6 (contains colons)
    elif [[ "$HOST" == *":"* ]]; then
        IS_IP=1
    fi

    if [ "$IS_IP" -eq 1 ]; then
        # Host is an IP, use default port 22
        PORT=22
        echo "Warning: Missing port. Using default port 22 for IP address."
    else
        # Host is a domain, use default port 443
        PORT=443
        echo "Warning: Missing port. Using default port 443 for domain name."
    fi
    
elif [ "$#" -eq 2 ]; then
    # Port is provided, perform validation
    PORT=$2
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        exit_error
    fi
fi

# ============================
# Logic: Resolve IP
# ============================
RESOLVED_IP=""

# 1. Check if HOST is already a valid IP address
if [[ "$HOST" =~ $IPV4_REGEX ]]; then
    if [ "$FORCE_IPV6" -eq 1 ]; then
        echo "Error: Host is IPv4, but -6 flag specified."
        exit 1
    fi
    RESOLVED_IP="$HOST"
elif [[ "$HOST" == *":"* ]]; then # Simple check for IPv6 format
    if [ "$FORCE_IPV4" -eq 1 ]; then
        echo "Error: Host is IPv6, but -4 flag specified."
        exit 1
    fi
    RESOLVED_IP="$HOST"
else
    # 2. If HOST is a domain, use getent/awk to resolve the IP
    RESOLVE_CMD="getent ahosts $HOST"
    
    if [ "$FORCE_IPV4" -eq 1 ]; then
        # Try to find IPv4
        RESOLVED_IP=$($RESOLVE_CMD | awk '{ if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $1; exit } }')
        if [ -z "$RESOLVED_IP" ]; then
            echo "Error: Failed to resolve IPv4 address for $HOST."
            exit 1
        fi
    elif [ "$FORCE_IPV6" -eq 1 ]; then
        # Try to find IPv6
        RESOLVED_IP=$($RESOLVE_CMD | awk '{ if ($1 ~ /:/) { print $1; exit } }')
        if [ -z "$RESOLVED_IP" ]; then
            echo "Error: Failed to resolve IPv6 address for $HOST."
            exit 1
        fi
    else
        # No forced version, pick the first one (usually v4)
        RESOLVED_IP=$($RESOLVE_CMD | awk '{ print $1; exit }')
        if [ -z "$RESOLVED_IP" ]; then
            echo "Error: Failed to resolve address for $HOST."
            exit 1
        fi
    fi
fi

# Determine display format for IP (add brackets for IPv6)
DISPLAY_IP="$RESOLVED_IP"
# Check if the resolved IP is IPv6
if [[ "$RESOLVED_IP" == *":"* ]]; then
    DISPLAY_IP="[$RESOLVED_IP]"
    # Additionally, ensure we use the correct protocol for connection if forced
    if [ "$FORCE_IPV4" -eq 1 ]; then
        echo "Error: Resolved IPv6 address ($RESOLVED_IP), but -4 flag specified."
        exit 1
    fi
elif [ "$FORCE_IPV6" -eq 1 ]; then
    # Additionally, ensure we use the correct protocol for connection if forced
    if [[ "$RESOLVED_IP" =~ $IPV4_REGEX ]]; then
        echo "Error: Resolved IPv4 address ($RESOLVED_IP), but -6 flag specified."
        exit 1
    fi
fi


# ============================
# Logic: Statistics Variables
# ============================
SENT=0
SUCCESS=0
FAILED=0
TOTAL_MS=0
MIN_MS=9999999
MAX_MS=0

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
echo "TCP Ping $HOST ($RESOLVED_IP) port $PORT"

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
        echo "Reply from $DISPLAY_IP:$PORT time=${RTT_INT}ms"

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
        echo "From $DISPLAY_IP:$PORT: Connection timed out"
        sleep 1
    fi
done

EOF

# ==========================================
# Post Install
# ==========================================
chmod +x "$INSTALL_PATH"
echo "[install-tcping] Done!"
