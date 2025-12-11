#!/bin/sh

echo "[tcping installer] Detecting system..."

# Detect package manager
PM=""
if command -v apt >/dev/null 2>&1; then
    PM="apt"
elif command -v yum >/dev/null 2>&1; then
    PM="yum"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
elif command -v apk >/dev/null 2>&1; then
    PM="apk"
else
    echo "Unsupported system: no apt/yum/dnf/apk found."
    exit 1
fi

echo "[tcping installer] Package manager detected: $PM"

# Install dependencies based on OS
case "$PM" in
    apt)
        echo "[tcping installer] Installing dependencies (Debian/Ubuntu)..."
        apt update -y >/dev/null 2>&1
        apt install -y bash coreutils libc-bin >/dev/null 2>&1
        ;;
    yum)
        echo "[tcping installer] Installing dependencies (RHEL/CentOS)..."
        yum install -y bash coreutils glibc-common >/dev/null 2>&1
        ;;
    dnf)
        echo "[tcping installer] Installing dependencies (Fedora/Rocky/Alma)..."
        dnf install -y bash coreutils glibc-common >/dev/null 2>&1
        ;;
    apk)
        echo "[tcping installer] Installing dependencies (Alpine)..."
        apk add bash busybox-extras libc6-compat >/dev/null 2>&1
        ;;
esac

# Ensure bash exists
if ! command -v bash >/dev/null 2>&1; then
    echo "Error: bash not installed!"
    exit 1
fi

echo "[tcping installer] Writing /usr/bin/tcping..."

cat << 'EOF' > /usr/bin/tcping
#!/bin/bash

if [ $# -lt 2 ]; then
    echo "Usage: $0 [-t] <host> <port>"
    exit 1
fi

loop=false
if [ "$1" == "-t" ]; then
    loop=true
    shift
fi

host="$1"
port="$2"

# Resolve IP for IPv4/IPv6
RESOLVED_IP=$(getent ahosts "$host" 2>/dev/null | head -n1 | awk '{print $1}')
if [ -z "$RESOLVED_IP" ]; then
    echo "Unknown host: $host"
    exit 1
fi

while true; do
    start=$(date +%s%3N)

    timeout 3 bash -c "echo > /dev/tcp/$host/$port" >/dev/null 2>&1
    RET=$?

    end=$(date +%s%3N)
    elapsed=$((end - start))

    if [ $RET -eq 0 ]; then
        printf "%s (%s):%d open - time=%d ms\n" "$host" "$RESOLVED_IP" "$port" "$elapsed"
    else
        printf "%s (%s):%d closed/timeout - time=%d ms\n" "$host" "$RESOLVED_IP" "$port" "$elapsed"
    fi

    if [ "$loop" = false ]; then
        break
    fi
    sleep 1
done
EOF

chmod +x /usr/bin/tcping

echo "[tcping installer] Installed successfully!"
echo "Usage: tcping [-t] host port"
