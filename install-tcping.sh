#!/usr/bin/env bash
set -e

# ===== Detect package manager =====
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

# ===== Check required runtime tools =====
required_tools=(bash date awk timeout)
missing_tools=()
for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing_tools+=("$t")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "Missing required tools: ${missing_tools[*]}"
    echo "tcping depends on: ${missing_tools[*]}"
    echo "Please install them first."
    case "$PM" in
        apt) echo "apt install -y ${missing_tools[*]}" ;;
        dnf|yum) echo "$PM install -y ${missing_tools[*]}" ;;
        apk) echo "apk add --no-cache ${missing_tools[*]}" ;;
    esac
    exit 1
fi

echo "[install-tcping] Dependencies OK"
echo "[install-tcping] Installing /usr/bin/tcping ..."

# ===== Install tcping =====
cat > /usr/bin/tcping << 'EOF'
#!/usr/bin/env bash

# Default values
FORCE_IP=""
COUNT_LIMIT=0
CURRENT_COUNT=0

usage() {
    echo "Usage: tcping [-4 | -6] [-c count] <host> <port>"
    echo "Options:"
    echo "  -4        Force IPv4"
    echo "  -6        Force IPv6"
    echo "  -c times  Run tcping N times, then exit"
    echo "  -h        Show this help"
    exit 0
}

error_usage() {
    echo "error: wrong argument"
    usage
}

while getopts ":46hc:" opt; do
    case $opt in
        4) FORCE_IP="-4" ;;
        6) FORCE_IP="-6" ;;
        c) COUNT_LIMIT="$OPTARG" ;;
        h) usage ;;
        *) error_usage ;;
    esac
done

shift $((OPTIND - 1))

HOST="$1"
PORT="$2"

if [ -z "$HOST" ] || [ -z "$PORT" ]; then
    error_usage
fi

# Validate count argument
if ! [[ "$COUNT_LIMIT" =~ ^[0-9]+$ ]]; then
    if [ "$COUNT_LIMIT" != "0" ]; then
        error_usage
    fi
fi

# Resolve IP
if [ "$FORCE_IP" = "-4" ]; then
    IP=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')
elif [ "$FORCE_IP" = "-6" ]; then
    IP=$(getent ahostsv6 "$HOST" | awk '{print $1; exit}')
else
    IP=$(getent ahosts "$HOST" | awk '{print $1; exit}')
fi

if [ -z "$IP" ]; then
    echo "Unknown host: $HOST"
    exit 1
fi

echo "TCP Ping $HOST ($IP) port $PORT"

COUNT=0
SUCCESS=0
FAILED=0
TOTAL_TIME=0
MIN_TIME=0
MAX_TIME=0

tcp_probe() {
    START=$(date +%s%3N)

    if timeout 2 bash -c "echo > /dev/tcp/$IP/$PORT" 2>/dev/null; then
        END=$(date +%s%3N)
        RTT=$((END - START))

        echo "Reply from $IP:$PORT time=${RTT}ms"

        COUNT=$((COUNT + 1))
        SUCCESS=$((SUCCESS + 1))
        TOTAL_TIME=$((TOTAL_TIME + RTT))

        if [ $MIN_TIME -eq 0 ] || [ $RTT -lt $MIN_TIME ]; then MIN_TIME=$RTT; fi
        if [ $RTT -gt $MAX_TIME ]; then MAX_TIME=$RTT; fi
    else
        echo "No response from $IP:$PORT"
        COUNT=$((COUNT + 1))
        FAILED=$((FAILED + 1))
    fi
}

trap ctrl_c INT

ctrl_c() {
    echo ""
    echo "Ping statistics for $IP:$PORT"
    echo "     $COUNT probes sent."
    echo "     $SUCCESS successful, $FAILED failed.  ($(awk "BEGIN {printf \"%.2f\", ($FAILED/$COUNT)*100}")% fail)"

    if [ $SUCCESS -gt 0 ]; then
        AVG=$(awk "BEGIN {printf \"%.3f\", $TOTAL_TIME/$SUCCESS}")
        echo "Approximate trip times in milli-seconds:"
        echo "     Minimum = ${MIN_TIME}ms, Maximum = ${MAX_TIME}ms, Average = ${AVG}ms"
    fi

    exit 0
}

# ===== Main loop =====
while true; do
    tcp_probe

    CURRENT_COUNT=$((CURRENT_COUNT + 1))
    if [ "$COUNT_LIMIT" -gt 0 ] && [ "$CURRENT_COUNT" -ge "$COUNT_LIMIT" ]; then
        ctrl_c
    fi

    sleep 1
done
EOF

chmod +x /usr/bin/tcping

echo "[install-tcping] Done!"
echo "Use: tcping [-4 | -6]()
