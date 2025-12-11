#!/usr/bin/env bash
set -e

echo "[install-tcping] Detecting package manager ..."

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

# ===== Install tcping script =====
cat <<'EOF' > /usr/bin/tcping
#!/usr/bin/env bash
# tcping - simple TCP probe using bash /dev/tcp
# Features:
#  - default: continuous probes (no -t)
#  - -c <count> : run count times then exit (print stats)
#  - -4 / -6 : force IPv4 / IPv6
#  - -h : help
#  - Ctrl+C : print stats and exit
#
# Output format:
#  per probe: Connected to host:port, seq=N time=Xms  (or failure)
#  summary same format you specified (3-decimal ms)

print_usage() {
    cat <<USAGE
Usage: tcping [-4] [-6] [-c count] <host> <port>
Options:
  -4         Force IPv4
  -6         Force IPv6
  -c count   Run tcping count times then exit
  -h         Show this help
USAGE
}

error_usage() {
    echo "error: wrong argument"
    print_usage
    exit 1
}

# parse args
force4=0
force6=0
count_limit=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -4) force4=1; shift ;;
        -6) force6=1; shift ;;
        -c)
            if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "error: wrong argument"
                print_usage
                exit 1
            fi
            count_limit="$2"
            shift 2
            ;;
        -h|--help) print_usage; exit 0 ;;
        -*)
            error_usage
            ;;
        *)
            if [[ -z "$host" ]]; then
                host="$1"
            elif [[ -z "$port" ]]; then
                port="$1"
            else
                error_usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$host" || -z "$port" ]]; then
    error_usage
fi

# resolver: try getent, then python3, then host -4/6, else leave hostname
resolve_ip() {
    local h="$1"
    local family="$2"  # "4" or "6" or ""
    local ip=""
    if command -v getent >/dev/null 2>&1; then
        if [[ "$family" == "4" ]]; then
            ip=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')
        elif [[ "$family" == "6" ]]; then
            ip=$(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1; exit}')
        else
            ip=$(getent ahosts "$h" 2>/dev/null | awk '{print $1; exit}')
        fi
    fi

    if [[ -z "$ip" && command -v python3 >/dev/null 2>&1 ]]; then
        if [[ "$family" == "4" ]]; then
            ip=$(python3 - <<PY -u
import socket,sys
try:
    ai=socket.getaddrinfo("$h", None, socket.AF_INET)
    print(ai[0][4][0] if ai else "")
except:
    pass
PY
)
        elif [[ "$family" == "6" ]]; then
            ip=$(python3 - <<PY -u
import socket,sys
try:
    ai=socket.getaddrinfo("$h", None, socket.AF_INET6)
    print(ai[0][4][0] if ai else "")
except:
    pass
PY
)
        else
            ip=$(python3 - <<PY -u
import socket,sys
try:
    ai=socket.getaddrinfo("$h", None)
    print(ai[0][4][0] if ai else "")
except:
    pass
PY
)
        fi
    fi

    # fallback: try host command
    if [[ -z "$ip" && command -v host >/dev/null 2>&1 ]]; then
        if [[ "$family" == "4" ]]; then
            ip=$(host -4 "$h" 2>/dev/null | awk '/has address/ {print $4; exit}')
        elif [[ "$family" == "6" ]]; then
            ip=$(host -6 "$h" 2>/dev/null | awk '/has IPv6 address/ {print $5; exit}')
        else
            ip=$(host "$h" 2>/dev/null | awk '/has address|has IPv6 address/ {print $NF; exit}')
        fi
    fi

    echo "$ip"
}

# determine IP to use
if [[ $force4 -eq 1 ]]; then
    IP=$(resolve_ip "$host" "4")
elif [[ $force6 -eq 1 ]]; then
    IP=$(resolve_ip "$host" "6")
else
    IP=$(resolve_ip "$host" "")
fi

if [[ -z "$IP" ]]; then
    echo "Unknown host: $host"
    exit 1
fi

# statistics
sent=0
recv=0
failed=0
sum_ms=0.0
min_ms=0
max_ms=0

# stop flag for Ctrl+C
stop=0
trap 'stop=1' INT

# print stats function (format matches your requested output)
print_stats() {
    echo ""
    echo "Ping statistics for ${IP}:${port}"
    echo "     ${sent} probes sent."
    echo "     ${recv} successful, ${failed} failed.  ($(awk "BEGIN{ if ($sent==0) print \"0.00\"; else printf \"%.2f\", ($failed*100)/$sent }")% fail)"
    if [[ $recv -gt 0 ]]; then
        avg=$(awk "BEGIN{printf \"%.3f\", $sum_ms / $recv}")
        minf=$(awk "BEGIN{printf \"%.3f\", $min_ms}")
        maxf=$(awk "BEGIN{printf \"%.3f\", $max_ms}")
        echo "Approximate trip times in milli-seconds:"
        echo "     Minimum = ${minf}ms, Maximum = ${maxf}ms, Average = ${avg}ms"
    else
        echo "Approximate trip times in milli-seconds:"
        echo "     No successful probes."
    fi
}

# probe once using /dev/tcp with timeout
probe_once() {
    local start end elapsed_ms
    # record start in ms; prefer date +%s%3N, fallback to nanoseconds then /1000000
    if date +%s%3N >/dev/null 2>&1; then
        start=$(date +%s%3N)
        # perform connection attempt
        if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${IP}/${port}" >/dev/null 2>&1; then
            end=$(date +%s%3N)
            elapsed_ms=$((end - start))
        else
            elapsed_ms=""
        fi
    else
        # fallback (some systems): use seconds nanoseconds
        start_ns=$(date +%s%N)
        if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${IP}/${port}" >/dev/null 2>&1; then
            end_ns=$(date +%s%N)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
        else
            elapsed_ms=""
        fi
    fi

    ((sent++))
    if [[ -n "$elapsed_ms" ]]; then
        # success
        echo "Connected to ${host}:${port}, seq=${sent} time=${elapsed_ms}ms"
        ((recv++))
        sum_ms=$(awk "BEGIN{printf \"%.6f\", $sum_ms + $elapsed_ms}")
        if [[ $min_ms -eq 0 || $elapsed_ms -lt $min_ms ]]; then min_ms=$elapsed_ms; fi
        if [[ $elapsed_ms -gt $max_ms ]]; then max_ms=$elapsed_ms; fi
    else
        echo "Connection to ${host}:${port} failed, seq=${sent}"
        ((failed++))
    fi
}

# main loop
while true; do
    # check if Ctrl+C requested
    if [[ $stop -eq 1 ]]; then
        print_stats
        exit 0
    fi

    probe_once

    # if count_limit specified and reached -> print stats and exit
    if [[ $count_limit -gt 0 && $sent -ge $count_limit ]]; then
        print_stats
        exit 0
    fi

    sleep 1
done
EOF

chmod +x /usr/bin/tcping
echo "[install-tcping] Done!"
echo "Use: tcping [-4] [-6] [-c count] <host> <port>"
