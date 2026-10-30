# derper-dashboard

A Grafana dashboard for a self-hosted [Tailscale DERP relay](https://tailscale.com/kb/1118/custom-derp-servers)
(`derper`), with a rootless installer that sets up Prometheus, node_exporter and Grafana next to it.

derper already exports Prometheus metrics at `/debug/varz`. This repo scrapes them, keeps them (60 days by default) and
charts:

- **Now:** connected clients, current throughput, bytes relayed and packets dropped over the time range, derper uptime
- **Traffic:** relayed throughput, the host's network interface, packets per second, average packet size
- **Drops and backpressure:** dropped packets by reason (`queue_head` means a client is being sent more than its
  link drains), share of bytes dropped, frames per write, client TCP RTT
- **Clients:** connections (home / not ideal), reconnect rate (spikes when derper restarts or a proxy reloads)
- **Host:** derper and host CPU, memory, TCP retransmits

## Install (no root, no Docker)

On the machine that runs derper:

```bash
git clone https://github.com/Sadashii/derper-dashboard.git
cd derper-dashboard
DERPER=127.0.0.1:443 ./install.sh
```

The installer downloads pinned releases of Prometheus, node_exporter and Grafana, checks their published SHA-256
sums, writes the configs under `~/derper-dashboard-data`, starts everything, and adds a `crontab @reboot` entry so it
comes back after a reboot. Re-run it to change settings or upgrade; your data is kept.

| Variable | Default | Meaning |
|---|---|---|
| `DERPER` | `127.0.0.1:443` | where derper serves HTTPS on this host. derper only answers `/debug/` on loopback and Tailscale addresses, so scrape it locally. If a proxy sits in front of derper, point this at derper's own listener (its `-a` flag). |
| `DERPER_SCHEME` | `https` | `http` if derper serves plain HTTP behind a TLS-terminating proxy |
| `GRAFANA_ADDR` | `127.0.0.1` | address Grafana listens on. Set your Tailscale IP to open it to your tailnet only. |
| `GRAFANA_PORT` | `3000` | |
| `ANONYMOUS` | `0` | `1` lets anyone who can reach Grafana view the dashboard read-only, without signing in |
| `RETENTION` | `60d` | how long Prometheus keeps data |
| `PREFIX` | `~/derper-dashboard-data` | where everything is installed |

Example: derper listening on `127.0.0.1:4443` behind nginx, dashboard open read-only to the tailnet:

```bash
DERPER=127.0.0.1:4443 GRAFANA_ADDR=100.x.y.z GRAFANA_PORT=3001 ANONYMOUS=1 RETENTION=70d ./install.sh
```

Grafana's admin password is generated on first install and saved in `~/derper-dashboard-data/grafana-admin-password`.
Prometheus (`:9090`) and node_exporter (`:9100`) listen on loopback only.

Manage the services with `~/derper-dashboard-data/run.sh start|stop|restart|status`. Logs are in
`~/derper-dashboard-data/logs/`.

## Already running Prometheus and Grafana?

Add a scrape job and import the dashboard:

```yaml
scrape_configs:
  - job_name: derper
    scheme: https
    metrics_path: /debug/varz
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ["127.0.0.1:443"]
```

Then import [`dashboards/derper.json`](dashboards/derper.json) in Grafana (Dashboards → New → Import) and pick your
Prometheus data source. The host panels also need [node_exporter](https://github.com/prometheus/node_exporter); the
rest work without it.

## Changing the dashboard

The JSON is generated: edit the panels in [`make_dashboard.py`](make_dashboard.py), run `python3 make_dashboard.py`,
and commit both files.

## License

MIT
