"""Generates dashboards/derper.json, a Grafana dashboard for a Tailscale DERP relay (derper).

It reads derper's own Prometheus metrics (/debug/varz) and, if you run it, node_exporter on the same host. Edit
the panels here, then run `python3 make_dashboard.py` and commit the JSON it writes.
"""
import json
from pathlib import Path

DS = {"type": "prometheus", "uid": "${datasource}"}
J = 'job="$job"'
panels, y = [], 0


def row(title):
    global y
    panels.append({"type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}})
    y += 1


def stat(title, expr, unit, x, w=4, decimals=None, thresholds=None, desc=""):
    p = {"type": "stat", "title": title, "description": desc, "datasource": DS,
         "gridPos": {"x": x, "y": y, "w": w, "h": 4},
         "targets": [{"refId": "A", "expr": expr, "instant": True}],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "graphMode": "none", "colorMode": "value"},
         "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "thresholds"},
                                      "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}},
                         "overrides": []}}
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    panels.append(p)


def ts(title, targets, unit, x, w, h=8, stack=False, desc=""):
    panels.append({"type": "timeseries", "title": title, "description": desc, "datasource": DS,
                   "gridPos": {"x": x, "y": y, "w": w, "h": h},
                   "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l} for i, (e, l) in enumerate(targets)],
                   "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
                   "fieldConfig": {"defaults": {"unit": unit, "custom": {
                       "fillOpacity": 15, "lineWidth": 1, "showPoints": "never",
                       "stacking": {"mode": "normal" if stack else "none"}}}, "overrides": []}})


bad = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 100}]}

row("Now")
stat("Clients connected", f"derp_current_connections{{{J}}}", "none", 0)
stat("Relayed in", f"rate(derp_bytes_received{{{J}}}[1m]) * 8", "bps", 4)
stat("Relayed out", f"rate(derp_bytes_sent{{{J}}}[1m]) * 8", "bps", 8)
stat("Relayed in range", f"sum(increase(derp_bytes_sent{{{J}}}[$__range]))", "decbytes", 12,
     desc="Bytes written out to clients over the selected time range.")
stat("Packets dropped in range", f"sum(increase(derp_packets_dropped{{{J}}}[$__range]))", "none", 16, decimals=0,
     thresholds=bad)
stat("derper uptime", f"time() - process_start_time_seconds{{{J}}}", "s", 20)
y += 4

row("Traffic")
ts("Relayed throughput", [(f"rate(derp_bytes_received{{{J}}}[1m]) * 8", "in"),
                          (f"rate(derp_bytes_sent{{{J}}}[1m]) * 8", "out")], "bps", 0, 12,
   desc="What derper reads from senders and writes to recipients. A relayed byte counts once in and once out.")
ts("Host network ($device)", [('rate(node_network_receive_bytes_total{device="$device"}[1m]) * 8', "rx"),
                              ('rate(node_network_transmit_bytes_total{device="$device"}[1m]) * 8', "tx")], "bps", 12, 12,
   desc="The relay host's interface, TLS overhead and anything else the host serves included (node_exporter).")
y += 8
ts("Packets relayed", [(f"rate(derp_packets_received{{{J}}}[1m])", "in"),
                       (f"rate(derp_packets_sent{{{J}}}[1m])", "out")], "pps", 0, 12)
ts("Average packet size", [(f"rate(derp_bytes_sent{{{J}}}[5m]) / rate(derp_packets_sent{{{J}}}[5m])", "bytes/packet")],
   "decbytes", 12, 12, desc="Close to the MTU during bulk transfers, small when the traffic is chatty.")
y += 8

row("Drops and backpressure")
ts("Packets dropped by reason", [(f"sum by (reason) (rate(derp_packets_dropped{{{J}}}[1m]))", "{{reason}}")], "pps", 0, 12,
   stack=True, desc="queue_head: a recipient's send queue was full, so derper dropped its oldest packet. A client "
                    "that is sent more than its link can drain shows up here. unknown_dest: the recipient isn't "
                    "connected to this relay.")
ts("Share of bytes dropped", [(f"sum(rate(derp_bytes_dropped{{{J}}}[5m])) / sum(rate(derp_bytes_received{{{J}}}[5m]))", "dropped")],
   "percentunit", 12, 12)
y += 8
ts("Frames per write", [
    (f"histogram_quantile(0.5, sum by (le) (rate(derp_buffered_write_frames_bucket{{{J}}}[5m])))", "p50"),
    (f"histogram_quantile(0.99, sum by (le) (rate(derp_buffered_write_frames_bucket{{{J}}}[5m])))", "p99")],
   "none", 0, 12, desc="Frames batched into one write to a client. Rises when clients fall behind.")
ts("Client TCP RTT samples by bucket", [(f"sum by (le) (rate(derp_tcp_rtt{{{J}}}[5m]))", "{{le}}")], "none", 12, 12, stack=True)
y += 8

row("Clients")
ts("Connections", [(f"derp_current_connections{{{J}}}", "connected"),
                   (f"derp_current_home_connections{{{J}}}", "home here"),
                   (f"derp_current_notideal_connections{{{J}}}", "not ideal")], "none", 0, 12)
ts("Reconnects", [(f"rate(derp_accepts{{{J}}}[5m]) * 60", "accepts/min")], "none", 12, 12,
   desc="A spike means many nodes reconnected at once: derper restarted, a proxy in front of it reloaded, or the network blipped.")
y += 8

row("Host")
ts("CPU", [(f"rate(process_cpu_seconds_total{{{J}}}[1m])", "derper (cores)"),
           ('sum(rate(node_cpu_seconds_total{mode!="idle"}[1m]))', "whole host (cores)")], "none", 0, 8)
ts("Memory", [(f"process_resident_memory_bytes{{{J}}}", "derper"),
              ("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "host in use")], "bytes", 8, 8)
ts("TCP retransmits", [("rate(node_netstat_Tcp_RetransSegs[1m])", "segments/s")], "none", 16, 8)
y += 8

variables = [
    {"name": "datasource", "label": "Data source", "type": "datasource", "query": "prometheus", "current": {}},
    {"name": "job", "label": "derper job", "type": "query", "datasource": DS, "refresh": 1,
     "query": {"query": "label_values(derp_current_connections, job)", "refId": "job"},
     "definition": "label_values(derp_current_connections, job)", "current": {}},
    {"name": "device", "label": "Interface", "type": "query", "datasource": DS, "refresh": 1,
     "query": {"query": 'label_values(node_network_receive_bytes_total{device!~"lo|tailscale.*|docker.*|veth.*|br-.*"}, device)',
               "refId": "device"},
     "definition": 'label_values(node_network_receive_bytes_total{device!~"lo|tailscale.*|docker.*|veth.*|br-.*"}, device)',
     "current": {}},
]
dash = {"uid": "derper", "title": "DERP relay (derper)", "tags": ["tailscale", "derp", "derper"], "timezone": "browser",
        "refresh": "30s", "time": {"from": "now-6h", "to": "now"}, "schemaVersion": 39, "version": 1,
        "panels": [dict(p, id=i + 1) for i, p in enumerate(panels)],
        "templating": {"list": variables}, "annotations": {"list": []}}
out = Path(__file__).resolve().parent / "dashboards" / "derper.json"
out.write_text(json.dumps(dash, indent=1) + "\n")
print(f"{out.name}: {len(panels)} panels")
