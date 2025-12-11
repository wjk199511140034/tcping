#!/usr/bin/env bash
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

# ===== Check runtime deps =====
required_tools=(bash date awk timeout)
missing_tools=()
for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing_tools+=("$t")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "Missing required tools: ${missing_tools[*]}"
    case "$PM" in
        apt) echo "apt install -y ${missing_tools[*]}" ;;
        dnf|yum) echo "$PM install -y ${missing_tools[*]}" ;;
        apk) echo "apk add --no-cache ${missing_tools[*]}" ;;
    esac
    exit 1
fi

# ===== Usage =====
usage() {
cat <<EOF
Usage: tcping [-4|-6] [-c times] host port
Options:
  -4        Use IPv4
  -6        Use IPv6
  -c N      Send N probes then stop
  -h        Show help
EOF
}

# ===== Parse args =====
force_v4=0
force_v6=0
count_limit=0

while [ $# -gt 0 ]; do
    case "$1" in
        -4) force_v4=1 ;;
        -6) force_v6=1 ;;
        -c)
            shift
            if ! echo "$1" | grep -qE '^[0-9]+$'; then
                echo "error: wrong argument"
                usage
                exit 1
            fi
            count_limit="$1"
            ;;
        -h)
            usage
            exit 0
            ;;
        -*)
            echo "error: wrong argument"
            usage
            exit 1
            ;;
        *)
            if [ -z "${host:-}" ]; then
                host="$1"
            elif [ -z "${port:-}" ]; then
                port="$1"
            else
                echo "error: wrong argument"
                usage
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "${host:-}" ] || [ -z "${port:-}" ]; then
    echo "error: wrong argument"
    usage
    exit 1
fi

# ===== Select ping command =====
ping_cmd="ping"
if [ "$force_v4" -eq 1 ]; then ping_cmd="ping -4"; fi
if [ "$force_v6" -eq 1 ]; then ping_cmd="ping -6"; fi

# ===== Stats =====
sent=0
success=0
min=999999
max=0
total=0

cleanup() {
    echo ""
    echo "Ping statistics for $host:$port"
    echo "     $sent probes sent."
    echo "     $success successful, $((sent-success)) failed.  ($(awk "BEGIN{printf \"%.2f\", ($sent-$success)/$sent*100}")% fail)"
    if [ "$success" -gt 0 ]; then
        avg=$(awk "BEGIN{printf \"%.3f\", $total/$success}")
        echo "Approximate trip times in milli-seconds:"
        echo "     Minimum = ${min}ms, Maximum = ${max}ms, Average = ${avg}ms"
    fi
    exit 0
}
trap cleanup INT

# ===== Loop =====
seq=0
while true; do
    seq=$((seq+1))
    sent=$((sent+1))

    start=$(date +%s%3N)
    if timeout 2 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        end=$(date +%s%3N)
        time_ms=$((end-start))
        echo "Connected to $host:$port, seq=$seq time=${time_ms}ms"

        success=$((success+1))
        total=$((total+time_ms))
        [ "$time_ms" -lt "$min" ] && min=$time_ms
        [ "$time_ms" -gt "$max" ] && max=$time_ms
    else
        echo "Failed to connect $host:$port, seq=$seq"
    fi

    if [ "$count_limit" -gt 0 ] && [ "$seq" -ge "$count_limit" ]; then
        cleanup
    fi
    sleep 1
done
