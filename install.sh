#!/usr/bin/env bash
# Rootless install of Prometheus + node_exporter + Grafana with the derper dashboard, all under one folder, started
# now and at every boot (crontab @reboot). No sudo, no Docker. Re-run it to change settings or upgrade; data is kept.
#
#   DERPER=127.0.0.1:443 GRAFANA_ADDR=127.0.0.1 GRAFANA_PORT=3000 ./install.sh
#
# Settings (environment variables):
#   PREFIX         where everything goes (default ~/derper-dashboard-data)
#   DERPER         host:port where derper serves HTTPS on this machine (default 127.0.0.1:443). derper only answers
#                  /debug/ from loopback or Tailscale addresses, so scrape it locally.
#   DERPER_SCHEME  https (default) or http, if derper runs with -certmode=manual behind a proxy that ends TLS
#   GRAFANA_ADDR   address Grafana listens on (default 127.0.0.1; use your Tailscale IP to share it on your tailnet)
#   GRAFANA_PORT   default 3000
#   ANONYMOUS      1 = anyone who can reach Grafana sees the dashboard read-only (default 0)
#   RETENTION      how long Prometheus keeps data (default 60d)
set -euo pipefail

PREFIX="${PREFIX:-$HOME/derper-dashboard-data}"
DERPER="${DERPER:-127.0.0.1:443}"
DERPER_SCHEME="${DERPER_SCHEME:-https}"
GRAFANA_ADDR="${GRAFANA_ADDR:-127.0.0.1}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
ANONYMOUS="${ANONYMOUS:-0}"
RETENTION="${RETENTION:-60d}"

PROM_VERSION=3.5.0
NODE_VERSION=1.9.1
GRAFANA_VERSION=12.1.1

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "unsupported CPU: $ARCH" >&2; exit 1 ;; esac

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$PREFIX"/{dl,bin,logs,prometheus-data,grafana-data,grafana/provisioning/datasources,grafana/provisioning/dashboards,dashboards}
cd "$PREFIX/dl"

put_bin() {   # put_bin <file>...: into bin/ by rename, so a running copy is replaced, not overwritten ("text file busy")
  for f in "$@"; do cp "$f" "$PREFIX/bin/.$(basename "$f").new" && mv -f "$PREFIX/bin/.$(basename "$f").new" "$PREFIX/bin/$(basename "$f")"; done
}

fetch() {   # fetch <url> <file>: download once
  [[ -s "$2" ]] && return
  curl -fsSL -o "$2.part" "$1" || die "download failed: $1"
  mv "$2.part" "$2"
}

say "Prometheus $PROM_VERSION"
P="prometheus-$PROM_VERSION.linux-$ARCH"
fetch "https://github.com/prometheus/prometheus/releases/download/v$PROM_VERSION/$P.tar.gz" "$P.tar.gz"
fetch "https://github.com/prometheus/prometheus/releases/download/v$PROM_VERSION/sha256sums.txt" "prom-$PROM_VERSION.sha256"
grep " $P.tar.gz\$" "prom-$PROM_VERSION.sha256" | sha256sum -c --quiet - || die "$P.tar.gz: checksum mismatch"
tar xzf "$P.tar.gz" && put_bin "$P/prometheus" "$P/promtool"

say "node_exporter $NODE_VERSION"
N="node_exporter-$NODE_VERSION.linux-$ARCH"
fetch "https://github.com/prometheus/node_exporter/releases/download/v$NODE_VERSION/$N.tar.gz" "$N.tar.gz"
fetch "https://github.com/prometheus/node_exporter/releases/download/v$NODE_VERSION/sha256sums.txt" "node-$NODE_VERSION.sha256"
grep " $N.tar.gz\$" "node-$NODE_VERSION.sha256" | sha256sum -c --quiet - || die "$N.tar.gz: checksum mismatch"
tar xzf "$N.tar.gz" && put_bin "$N/node_exporter"

say "Grafana $GRAFANA_VERSION"
G="grafana-$GRAFANA_VERSION.linux-$ARCH.tar.gz"
fetch "https://dl.grafana.com/oss/release/$G" "$G"
fetch "https://dl.grafana.com/oss/release/$G.sha256" "$G.sha256"
echo "$(cat "$G.sha256")  $G" | sha256sum -c --quiet - || die "$G: checksum mismatch"
[[ -d "$PREFIX/grafana-$GRAFANA_VERSION" ]] || tar xzf "$G" -C "$PREFIX"
ln -sfn "$PREFIX/grafana-$GRAFANA_VERSION" "$PREFIX/grafana-current"

say "Configuration"
sed -e "s|@DERPER@|$DERPER|" -e "s|@DERPER_SCHEME@|$DERPER_SCHEME|" "$HERE/prometheus/prometheus.yml" > "$PREFIX/prometheus.yml"
"$PREFIX/bin/promtool" check config "$PREFIX/prometheus.yml" >/dev/null
cp "$HERE/grafana/provisioning/datasources/prometheus.yml" "$PREFIX/grafana/provisioning/datasources/"
sed "s|@DASHBOARDS@|$PREFIX/dashboards|" "$HERE/grafana/provisioning/dashboards/derper.yml" > "$PREFIX/grafana/provisioning/dashboards/derper.yml"
cp "$HERE/dashboards/derper.json" "$PREFIX/dashboards/"

PASS_FILE="$PREFIX/grafana-admin-password"
if [[ ! -s "$PASS_FILE" ]]; then
  (umask 077; head -c 18 /dev/urandom | base64 | tr -d '/+=' > "$PASS_FILE")
fi
anon=false; [[ "$ANONYMOUS" == 1 ]] && anon=true
cat > "$PREFIX/grafana.ini" <<EOF
[paths]
data = $PREFIX/grafana-data
logs = $PREFIX/logs
plugins = $PREFIX/grafana-data/plugins
provisioning = $PREFIX/grafana/provisioning
[server]
http_addr = $GRAFANA_ADDR
http_port = $GRAFANA_PORT
[security]
admin_user = admin
admin_password = \$__file{$PASS_FILE}
[auth.anonymous]
enabled = $anon
org_role = Viewer
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
[dashboards]
default_home_dashboard_path = $PREFIX/dashboards/derper.json
EOF

cat > "$PREFIX/run.sh" <<EOF
#!/usr/bin/env bash
# start | stop | restart | status
PREFIX="$PREFIX"
RETENTION="$RETENTION"
EOF
cat >> "$PREFIX/run.sh" <<'EOF'
cd "$PREFIX"
procs=(node_exporter prometheus grafana)
start_one() {
  local name=$1; shift
  if [[ -s "logs/$name.pid" ]] && kill -0 "$(cat "logs/$name.pid")" 2>/dev/null; then return; fi
  setsid nohup "$@" >> "logs/$name.log" 2>&1 < /dev/null &
  echo $! > "logs/$name.pid"
}
case "${1:-start}" in
  start)
    start_one node_exporter bin/node_exporter --web.listen-address=127.0.0.1:9100
    start_one prometheus bin/prometheus --config.file=prometheus.yml --storage.tsdb.path=prometheus-data \
      --storage.tsdb.retention.time="$RETENTION" --web.listen-address=127.0.0.1:9090
    start_one grafana grafana-current/bin/grafana server --homepath grafana-current --config grafana.ini ;;
  stop)
    for p in "${procs[@]}"; do [[ -s "logs/$p.pid" ]] && kill "$(cat "logs/$p.pid")" 2>/dev/null; rm -f "logs/$p.pid"; done ;;
  restart) "$0" stop; sleep 2; "$0" start ;;
  status)
    for p in "${procs[@]}"; do
      if [[ -s "logs/$p.pid" ]] && kill -0 "$(cat "logs/$p.pid")" 2>/dev/null; then echo "$p: running"; else echo "$p: stopped"; fi
    done ;;
esac
EOF
chmod +x "$PREFIX/run.sh"

say "Start at boot (crontab @reboot)"
line="@reboot $PREFIX/run.sh start"
( crontab -l 2>/dev/null | grep -vF "$PREFIX/run.sh" ; echo "$line" ) | crontab -

say "Starting"
"$PREFIX/run.sh" restart
sleep 5
"$PREFIX/run.sh" status
if curl -fsS -m 5 "http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22derper%22%7D" | grep -q '"value":\[[^]]*,"1"\]'; then
  say "Prometheus reaches derper at $DERPER_SCHEME://$DERPER"
else
  printf '\033[1;33m[!]\033[0m Prometheus does not reach derper yet: check DERPER (%s) and %s/logs/prometheus.log\n' "$DERPER" "$PREFIX"
fi
say "Grafana: http://$GRAFANA_ADDR:$GRAFANA_PORT (user admin, password in $PASS_FILE)"
