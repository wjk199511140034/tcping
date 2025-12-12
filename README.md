## tcping for Debian / Ubuntu / CentOS / Alpine<br>
Install:<br>
```
wget -O - https://raw.githubusercontent.com/wjk199511140034/tcping/main/install-tcping.sh | bash
```
Or:<br>
```
curl -sSL https://raw.githubusercontent.com/wjk199511140034/tcping/main/install-tcping.sh | bash
```
<br>
Usage: <br>

```
tcping [-4|-6] [-c times] host port
Options:
  -4        Use IPv4
  -6        Use IPv6
  -c N      Send N probes then stop
  -h        Show help
```
