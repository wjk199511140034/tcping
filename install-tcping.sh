#!/usr/bin/env bash

set -e

# ===== System check =====
if [ -f /etc/debian_version ]; then
    SYS="debian"
elif [ -f /etc/redhat-release ]; then
    SYS="redhat"
elif [ -f /etc/alpine-release ]; then
    SYS="alpine"
else
    echo "Unsupported Linux distribution."
    exit 1
fi

# ===== Dependency check =====
deps=("bash" "nc" "ping" "awk" "date")
missing=()

for d in "${deps[@]}"; do
    if ! command -v $d >/dev/null 2>&1; then
        missing+=("$d")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "tcping depends on: ${missing[*]}"
    echo "Please install missing dependencies first."
    exit 1
fi

# ===== Install tcping =====
cat > /usr/bin/tcping << 'EOF'
#!/usr/bin/env bash

# Default values
FORCE_IP=""
REPEAT=0

usage() {
    echo "Usage: tcping [-4 | -6] [-t] <host> <port>"
    echo "Options:"
    echo "  -4        Force IPv4"
    echo "  -6        Force IPv6"
    echo "  -t        Loop until Ctrl+C"
    echo "  -h        Show this help"
    exit 0
}

while getopts ":46th" opt; do
    case $opt in
        4) FORCE_IP="-4" ;;
        6) FORCE_IP="-6" ;;
        t) REPEAT=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

shift $((OPTIND - 1))

HOST="$1"
PORT="$2"

if [ -z "$HOST" ] || [ -z "$PORT" ]; then
    usage
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

    # nc -z: just check port
    # timeout 2s to avoid long wait
    if timeout 2 bash -c "echo > /dev/tcp/$IP/$PORT" 2>/dev/null; then
        END=$(date +%s%3N)
        RTT=$((END - START))

        echo "Reply from $IP:$PORT time=${RTT}ms"

        COUNT=$((COUNT + 1))
        SUCCESS=$((SUCCESS + 1))
        TOTAL_TIME=$((TOTAL_TIME + RTT))

        # update min/max
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

# Main loop
if [ $REPEAT -eq 1 ]; then
    while true; do
        tcp_probe
        sleep 1
    done
else
    tcp_probe
fi
EOF

chmod +x /usr/bin/tcping

echo "tcping installed successfully."
echo "Usage: tcping [-4 | -6] [-t] <host> <port>"
