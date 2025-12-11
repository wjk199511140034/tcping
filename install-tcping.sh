#!/usr/bin/env bash

# ================================
# Detect package manager
# ================================
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

# ================================
# Check required runtime tools
# ================================
required_tools=(bash date awk timeout)
missing_tools=()
for t in "${required_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        missing_tools+=("$t")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "Missing dependency: ${missing_tools[*]}"
    case "$PM" in
        apt) echo "pleasse install it frist" ;;
        dnf|yum) echo "please install it first" ;;
        apk) echo "please install it first" ;;
    esac
    exit 1
fi

echo "[install-tcping] Dependencies OK"

# ================================
# Install tcping script
# ================================
install_path="/usr/bin/tcping"
echo "[install-tcping] Installing $install_path ..."

cat > "$install_path" <<'EOF'
#!/usr/bin/env bash

# ===== Usage =====
usage() {
cat <<USAGE
Usage: tcping [-4|-6] [-c times] host port
Options:
  -4        Use IPv4
  -6        Use IPv6
  -c N      Send N probes then stop
  -h        Show help
USAGE
}

# ===== Argument parse =====
use_ipv4=0
use_ipv6=0
count=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -4) use_ipv4=1 ;;
        -6) use_ipv6=1 ;;
        -c)
            shift
            [[ "$1" =~ ^[0-9]+$ ]] || {
                echo "error: -c needs a number"
                usage
                exit 1
            }
            count="$1"
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
            if [ -z "$host" ]; then
                host="$1"
            elif [ -z "$port" ]; then
                port="$1"
            else
                echo "error: too many arguments"
                usage
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$host" ] || [ -z "$port" ]; then
    echo "error: missing host or port"
    usage
    exit 1
fi

# ===== Resolve IP =====
ip=$(getent ahosts "$host" | awk -v v6=$use_ipv6 -v v4=$use_ipv4 '/STREAM/ {if(v6==1 && $1~/\:/){print $1; exit} if(v4==1 && $1!~/\:/){print $1; exit} if(v6==0 && v4==0){print $1; exit}}')
[ -z "$ip" ] && ip="$host"

echo "TCP Ping $host ($ip) port $port"

# ===== Statistics =====
sent=0
ok=0
fail=0
min_time=999999
max_time=0
sum_time=0

# ===== Ctrl+C handler =====
finish() {
    echo ""
    echo "tcping statistics for $ip:$port"
    echo "     $sent probes sent."
    echo "     $ok successful, $fail failed.  ($(awk "BEGIN{printf \"%.2f\", $fail*100/$sent}")% fail)"
    if [ $ok -gt 0 ]; then
        avg=$(awk "BEGIN{printf \"%.3f\", $sum_time/$ok}")
        echo "Approximate trip times in milli-seconds:"
        echo "     Minimum = ${min_time}ms, Maximum = ${max_time}ms, Average = ${avg}ms"
    fi
    exit 0
}

trap finish INT

# ===== Main loop =====
while true; do
    start=$(date +%s%3N)

    if timeout 2 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
        end=$(date +%s%3N)
        cost=$((end - start))
        echo "Reply from $ip:$port time=${cost}ms"

        ((ok++))
        ((sent++))
        sum_time=$((sum_time+cost))
        (( cost < min_time )) && min_time=$cost
        (( cost > max_time )) && max_time=$cost
    else
        echo "No response from $ip:$port"
        ((fail++))
        ((sent++))
    fi
    sleep 1


    # stop if count reached
    if [ $count -gt 0 ] && [ $sent -ge $count ]; then
        finish
    fi
done
EOF

chmod +x "$install_path"

echo "[install-tcping] Done!"
