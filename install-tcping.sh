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
cat << 'EOF' > /usr/bin/tcping
#!/usr/bin/env bash

force4=0
force6=0
count=0
host=""
port=""

show_help() {
    echo "Usage: tcping [-4] [-6] [-c count] <host> <port>"
}

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        -4) force4=1; shift ;;
        -6) force6=1; shift ;;
        -c)
            if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "error: wrong argument"
                show_help
                exit 1
            fi
            count="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "error: wrong argument"
            show_help
            exit 1
            ;;
        *)
            if [[ -z "$host" ]]; then
                host="$1"
            elif [[ -z "$port" ]]; then
                port="$1"
            else
                echo "error: wrong argument"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$host" || -z "$port" ]]; then
    echo "error: wrong argument"
    show_help
    exit 1
fi

# ===== Prepare exec =====
ip_flag=""
[[ $force4 -eq 1 ]] && ip_flag="-4"
[[ $force6 -eq 1 ]] && ip_flag="-6"

sent=0
success=0
fail=0
sum=0
min=999999
max=0

print_stats() {
    echo ""
    echo "Ping statistics for $host:$port"
    echo "     $sent probes sent."
    echo "     $success successful, $fail failed.  ($(awk "BEGIN{printf \"%.2f\", ($fail/$sent)*100}")% fail)"
    echo "Approximate trip times in milli-seconds:"
    if [[ $success -gt 0 ]]; then
        avg=$(awk "BEGIN {printf \"%.3f\", $sum/$success}")
        echo "     Minimum = ${min}ms, Maximum = ${max}ms, Average = ${avg}ms"
    else
        echo "     No successful probes."
    fi
}

trap print_stats INT

probe_once() {
    local start end diff
    start=$(date +%s%N)
    if timeout 2 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        end=$(date +%s%N)
        diff=$(( (end-start)/1000000 ))
        echo "Connected to $host:$port, seq=$sent time=${diff}ms"

        ((success++))
        sum=$((sum+diff))
        [[ $diff -lt $min ]] && min=$diff
        [[ $diff -gt $max ]] && max=$diff
    else
        echo "Connection to $host:$port failed, seq=$sent"
        ((fail++))
    fi
}

# ===== Loop =====
while true; do
    ((sent++))
    probe_once

    if [[ $count -gt 0 && $sent -ge $count ]]; then
        print_stats
        exit 0
    fi

    sleep 1
done
EOF

chmod +x /usr/bin/tcping
echo "[install-tcping] Done!"
