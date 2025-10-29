etcd-sentinel\
───────────────────────────────\
🧠 Lightweight remote etcd health monitor with Splunk/HEC integration

───────────────────────────────\
🚀 What it is

etcd-sentinel is a minimal, zero-agent monitoring script for your etcd clusters.\
It runs from anywhere with SSH access, collects cluster metrics remotely, checks database growth, and can push structured results to Splunk via HTTP Event Collector (HEC).

No agents. No daemons. No containers.\
Just a single Bash script doing one job extremely well.

───────────────────────────────\
💡 Why you might actually want it

Because etcd is the beating heart of your control plane---and it tends to silently grow until something breaks.\
Most monitoring tools require exporters, sidecars, or Prometheus scraping. etcd-sentinel doesn't.

It's designed for environments where:\
- You can't install extra software on control plane nodes.\
- You still need visibility into etcd DB size and health.\
- You prefer one command and a clean JSON output over yet another dashboard.

───────────────────────────────\
⚙️ What it does

- Connects remotely via SSH to your etcd manager node.\
- Executes `etcdctl --cluster=true endpoint status -w json`.\
- Calculates average and maximum database size across all nodes.\
- Detects the current leader and reports health status.\
- Compares usage against configurable thresholds (in GB).\
- Optionally ships metrics to Splunk in JSON format.\
- Outputs both human-readable and machine-readable summaries.

───────────────────────────────\
🪶 Features at a glance

✅ Zero installation on target nodes\
✅ Built-in thresholds and severity evaluation\
✅ Works with any etcd 3.x cluster\
✅ Compatible with Splunk, Loki, or any REST ingestion endpoint\
✅ Pure Bash + jq (portable, audit-friendly, 0 dependencies)\
✅ Can run as a cronjob or as part of CI/CD pipelines

───────────────────────────────\
🧩 Example run

===> Checking ETCD status @ etcd-prod-1 (PROD)
Leader: etcd-prod-2\
Max DB size: 1.74 GB (86%)\
Status: WARNING\
Message: WARNING: etcd DB size approaching limit (86% of 2 GB)
✅ Sent metrics to Splunk HEC\
ETCD sentinel check completed (exit code: 1)

───────────────────────────────\
🛠 How to use it

Clone and run:\
git clone <https://github.com/><your-org>/etcd-sentinel.git\
cd etcd-sentinel\
chmod +x etcd-sentinel.sh

Basic check (no Splunk):\
./etcd-sentinel.sh --target etcd-node-01 --env PROD

With Splunk integration:\
./etcd-sentinel.sh --target etcd-node-01 --env PROD --splunk-url "https://splunk.example.com/services/collector/event" --splunk-token "YOUR_TOKEN" --index "cluster-logs"

───────────────────────────────\
🔍 Configuration options

--target → remote node (required)\
--env → environment name (PROD / NOPROD)\
--splunk-url → Splunk HEC endpoint\
--splunk-token → HEC token\
--index → Splunk index name (default: cluster-logs)\
--warn → warning threshold (GB)\
--crit → critical threshold (GB)

Default thresholds:\
NOPROD → warn 3 GB / crit 4 GB\
PROD → warn 1.5 GB / crit 2 GB

───────────────────────────────\
📊 Splunk integration

Each run emits a structured JSON payload that can be indexed directly in Splunk:

{\
"environment": "PROD",\
"manager": "etcd-prod-1",\
"status": "WARNING",\
"usage_percent": 86,\
"max_db_size_bytes": 1870659584,\
"leader": "etcd-prod-2"\
}

Suggested Splunk fields:\
index = docker_system-logs\
source = etcd-sentinel\
sourcetype = etcd-sentinel-json\
service = etcd_sentinel

This makes it trivial to create dashboards showing size trends, leader rotation, or threshold violations.

───────────────────────────────\
🧠 Why it's different

etcd-sentinel was built to work under the constraints most people forget:\
air-gapped environments, isolated networks, enterprise clusters with strict change management.

It doesn't assume you can run containers, install exporters, or rely on kube-system scraping.\
It just uses the oldest, most reliable API there is: SSH.

───────────────────────────────\
🔐 Security notes

- Requires only SSH access; no persistent connection or background agent.\
- The only remote command executed is `docker exec` on the etcd container.\
- No secrets stored on disk --- Splunk tokens can be passed as environment variables.

───────────────────────────────\
🧪 Exit codes

0 → OK (within limits)\
1 → WARNING (approaching threshold)\
2 → CRITICAL (exceeds threshold)

Perfect for use in automation pipelines or alerting scripts.

───────────────────────────────\
📦 Roadmap

[ ] JSON export mode (--json)\
[ ] Prometheus textfile exporter\
[ ] Slack / Teams native notifications\
[ ] etcd v3.6 API support\
[ ] Multi-cluster parallel mode

───────────────────────────────\
🪪 License

MIT License\
© 2025 Marco Gomiero

───────────────────────────────\
💬 Tagline

"Born inside a production cluster, open-sourced to help others keep etcd small, stable, and happy."