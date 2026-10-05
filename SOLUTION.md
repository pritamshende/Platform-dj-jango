# Platform Engineer — Technical Assignment Solution

> **Author:** Pritam Shende
> **Date:** October 2026
> **Stack:** Django 5.2 / Gunicorn / Nginx / PostgreSQL on AWS EC2

---

## Table of Contents

1. [Part 1: Deployment Approach](#part-1-deployment-approach)
2. [Part 2: CI/CD Pipeline](#part-2-cicd-pipeline)
3. [Part 3: Production Incident Investigation (502 Bad Gateway)](#part-3-production-incident-investigation)
4. [Part 4: Security Review](#part-4-security-review)
5. [Part 5: Health-Check Endpoint](#part-5-health-check-endpoint)
6. [Part 6: AWS Architecture](#part-6-aws-architecture)
7. [File Index](#file-index)

---

## Part 1: Deployment Approach

### 1.1 Server Setup and Package Installation

The application runs on an **Ubuntu LTS EC2 instance** in a private subnet. Initial server preparation:

```bash
# System packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-venv python3-pip nginx postgresql-client curl jq

# Dedicated application user (no login shell)
sudo useradd --system --home /opt/platform --shell /usr/sbin/nologin platform

# Directory structure
sudo install -d -o root -g platform -m 0750 /etc/platform
sudo install -d -o root -g root   -m 0755 /opt/platform/releases
sudo install -d -o platform -g platform -m 0750 /var/lib/platform
sudo install -d -o platform -g platform -m 0755 /var/lib/platform/static
```

### 1.2 Application Directory Structure

```
/opt/platform/
├── releases/
│   ├── abc1234/               # Release by commit SHA
│   │   ├── .venv/             # Isolated virtual environment
│   │   ├── config/
│   │   ├── manage.py
│   │   └── requirements.txt
│   └── def5678/               # Previous release
├── current -> releases/abc1234  # Atomic symlink to active release
/etc/platform/
└── platform.env               # Runtime environment (root:root 0600)
/var/lib/platform/
├── static/                    # Collected static files (Nginx-served)
└── media/                     # User uploads (optional)
```

Each deployment creates a **new release directory** with its own virtualenv. The `current` symlink is swapped atomically to activate a release.

### 1.3 Environment Variable Management

All secrets are stored in **AWS Secrets Manager** and retrieved at instance boot via the EC2 instance role. They are written to `/etc/platform/platform.env` (mode `0600`, owned by root). Systemd's `EnvironmentFile=` directive loads them into the service process.

```ini
# /etc/platform/platform.env (example — never commit real values)
DJANGO_SETTINGS_MODULE=config.settings
DJANGO_SECRET_KEY=<retrieved-from-secrets-manager>
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=platform.example.com
DB_HOST=<private-rds-endpoint>
DB_PORT=5432
DB_NAME=platform
DB_USER=platform_app
DB_PASSWORD=<retrieved-from-secrets-manager>
```

### 1.4 Dependency Installation

```bash
python3 -m venv /opt/platform/releases/<sha>/.venv
/opt/platform/releases/<sha>/.venv/bin/pip install --upgrade pip
/opt/platform/releases/<sha>/.venv/bin/pip install -r requirements.txt
```

Dependencies are **pinned** in `requirements.txt` and tested in CI before deployment.

### 1.5 Application Server Configuration

Gunicorn runs as a **systemd service** under the `platform` user, bound to `127.0.0.1:8000` (never exposed externally).

See: [`ops/platform.service`](ops/platform.service)

Key settings:
- 2 workers (starting point; adjust after load testing)
- 30s request timeout
- Automatic restart on failure with 5s backoff
- Systemd hardening: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`

```bash
sudo cp ops/platform.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now platform
```

### 1.6 Nginx Configuration

Nginx acts as a **reverse proxy** in front of Gunicorn and serves static files directly.

See: [`ops/platform-nginx.conf`](ops/platform-nginx.conf)

Key design decisions:
- Default server returns 404 for unknown Host headers
- ALB health checks are proxied on the default vhost with a hardcoded Host header
- Static files are served from `/var/lib/platform/static/` with 30-day caching
- Hidden files (`.env`, `.git`) are denied

```bash
sudo cp ops/platform-nginx.conf /etc/nginx/sites-available/platform
sudo ln -sf /etc/nginx/sites-available/platform /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

### 1.7 SSL Certificate Setup

HTTPS terminates at the **Application Load Balancer** using an **ACM certificate**:

1. Request a certificate in ACM for `platform.example.com`
2. Validate via DNS (Route 53 CNAME record)
3. Attach to the ALB HTTPS listener (port 443)
4. ALB HTTP listener (port 80) redirects to HTTPS
5. Configure Django: `SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")`

For deployments without an ALB, use Certbot/Let's Encrypt directly on Nginx.

### 1.8 Application Startup and Restart

```bash
# Start/restart
sudo systemctl restart platform

# Check status
sudo systemctl status platform --no-pager

# View logs
sudo journalctl -u platform -f
```

### 1.9 Log Locations

| Log | Location |
|-----|----------|
| Application (stdout/stderr) | `journalctl -u platform` |
| Nginx access log | `/var/log/nginx/access.log` |
| Nginx error log | `/var/log/nginx/error.log` |
| Deployment log | SSM command output in CloudWatch |

All logs are forwarded to **CloudWatch Logs** via the CloudWatch agent.

### 1.10 Deployment Rollback Approach

The deployment script ([`ops/deploy.sh`](ops/deploy.sh)) implements **automatic rollback**:

1. Before activating a new release, the current symlink target is recorded
2. After restart, health checks run with retries (10 attempts × 3s interval)
3. If health checks fail, the `current` symlink is restored to the previous release
4. The application is restarted and the deployment is marked as failed

**Important:** Code rollback is safe only when database migrations are backward-compatible. We use additive-only migrations (add columns, don't drop) and remove old columns in a subsequent release.

---

## Part 2: CI/CD Pipeline

The pipeline uses **GitHub Actions** with OIDC authentication (no long-lived AWS credentials).

See: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

### Pipeline Flow

```
Push to main
    │
    ▼
┌─────────────────────────┐
│  1. Checkout code       │
│  2. Setup Python 3.12   │
│  3. Install dependencies│
│  4. Run Django tests    │
│     (PostgreSQL service)│
└────────────┬────────────┘
             │ Tests pass
             ▼
┌─────────────────────────┐
│  5. OIDC → AWS creds    │
│  6. Package as .tar.gz  │
│  7. Upload to S3        │
│  8. Deploy via SSM      │
│  9. Wait for completion │
│ 10. Verify ALB health   │
└────────────┬────────────┘
             │ Health check fails
             ▼
┌─────────────────────────┐
│ 11. Automatic rollback  │
│     via SSM command     │
└─────────────────────────┘
```

### Key Security Features

- **OIDC** — No static AWS credentials stored in GitHub Secrets
- **Concurrency control** — Only one production deploy at a time
- **Environment protection** — `production` environment with required reviewers
- **SSM** — No SSH keys; commands run through Systems Manager

---

## Part 3: Production Incident Investigation

### Scenario: 502 Bad Gateway after deployment

### Step-by-step Investigation

| # | Command | What It Reveals |
|---|---------|-----------------|
| 1 | `sudo systemctl status platform --no-pager` | Is the app running? Is it crash-looping? |
| 2 | `sudo journalctl -u platform -n 200 --no-pager` | Import errors, missing settings, DB connection failures, OOM kills |
| 3 | `sudo tail -n 100 /var/log/nginx/error.log` | Upstream connection refused, timeouts, permission errors |
| 4 | `sudo tail -n 100 /var/log/nginx/access.log` | Which paths return 502, request patterns |
| 5 | `sudo nginx -t` | Is the Nginx config valid? |
| 6 | `sudo ss -lntp` | Is anything listening on 127.0.0.1:8000? |
| 7 | `curl -sI -H 'Host: platform.example.com' http://127.0.0.1:8000/health/live/` | Does Gunicorn respond without Nginx? |
| 8 | `curl -sI -H 'Host: platform.example.com' http://127.0.0.1/health/ready/` | Does the full Nginx→Gunicorn→DB path work? |
| 9 | `namei -l /opt/platform/current/.venv/bin/gunicorn` | Permission issues on the executable path |
| 10 | `df -h && free -m` | Disk full or memory exhaustion |
| 11 | ALB target health in AWS Console | Unhealthy targets, 5xx from target vs ALB |

### Common Root Causes

1. **Gunicorn not running** — Missing dependency, import error, bad env var → fix and restart
2. **Wrong bind address/port** — Gunicorn not on 127.0.0.1:8000 → fix systemd config
3. **Symlink broken** — `current` points to missing directory → re-link or rollback
4. **Database unreachable** — Security group, RDS endpoint, credentials → check connectivity
5. **Disk full** — Logs or old releases filling disk → clean up, rotate logs
6. **OOM killer** — Workers consuming too much memory → reduce workers, increase instance size
7. **Permission denied** — New release owned by wrong user → fix ownership

### Recovery Steps

1. **If the new release caused it:** Rollback to previous release
   ```bash
   ln -sfn /opt/platform/releases/<previous-sha> /opt/platform/current
   sudo systemctl restart platform
   ```
2. **Verify health** after rollback
3. **Preserve logs** before any cleanup for post-incident analysis
4. **Document** the cause, impact, recovery action, and prevention measure

---

## Part 4: Security Review

| # | Risk | Impact | Remediation |
|---|------|--------|-------------|
| 1 | **Secrets in source code** | Credential exposure if repo is compromised | Store in AWS Secrets Manager; load via env vars at runtime; rotate any exposed values immediately |
| 2 | **Overly permissive IAM** | Lateral movement, data exfiltration | Separate roles for deployment and EC2; scope to specific S3 prefixes, secrets, SSM documents |
| 3 | **Publicly exposed database** | Direct SQL access from the internet | RDS in private subnet; SG allows 5432 only from EC2 SG; disable public access |
| 4 | **Open SSH port (22)** | Brute-force attacks, unauthorized access | Use SSM Session Manager instead; no inbound SSH in security groups |
| 5 | **Missing HTTPS** | Data interception, credential theft | ACM certificate on ALB; HTTP→HTTPS redirect; `SECURE_SSL_REDIRECT=True` in Django |
| 6 | **Debug mode enabled in production** | Stack traces leak internal paths, settings | `DJANGO_DEBUG=False`; run `manage.py check --deploy` in CI |
| 7 | **Application running as root** | Full system compromise on app vulnerability | Dedicated `platform` user; systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`) |
| 8 | **Outdated dependencies** | Known CVE exploitation | Pin versions; use `pip-audit` or Dependabot; test and apply security patches |
| 9 | **Missing backups** | Data loss on failure or corruption | RDS automated backups (7-day retention); S3 versioning; test restore procedure |
| 10 | **Missing monitoring/alerts** | Silent failures, undetected breaches | CloudWatch alarms for CPU, error rates, unhealthy targets; alert to Slack/PagerDuty |
| 11 | **Unsafe deployment access** | Unauthorized code deployment | OIDC (no static creds); protected `main` branch; required PR reviews; GitHub environment protection |
| 12 | **No audit logging** | Cannot trace who did what | Enable CloudTrail; SSM session logging; deployment logs in CloudWatch |

---

## Part 5: Health-Check Endpoint

See: [`config/health.py`](config/health.py)

### Liveness Endpoint: `GET /health/live/`

Returns `200 OK` if the WSGI process is responding:

```json
{"status": "ok"}
```

Used by the ALB target group health check.

### Readiness Endpoint: `GET /health/ready/`

Checks database connectivity by executing `SELECT 1`:

**Success (200):**
```json
{"status": "ok", "database": "ok"}
```

**Database unavailable (503):**
```json
{"status": "unavailable", "database": "unreachable"}
```

Used by the deployment script to verify end-to-end health after a release.

### Design Decisions

- **No authentication** required — health endpoints are internal-only (not exposed via ALB to the public)
- **No sensitive data** in responses — no connection strings or exception details
- **Bounded query timeout** — database connection has a 5s timeout configured in settings
- **Separate concerns** — liveness ≠ readiness; a DB outage shouldn't cause unnecessary app restarts

---

## Part 6: AWS Architecture

### Architecture Overview

```
                          ┌─────────────┐
                          │  Route 53   │
                          │ (DNS CNAME) │
                          └──────┬──────┘
                                 │
                          ┌──────▼──────┐
                          │     ALB     │
                          │ (HTTPS/443) │
                          │ ACM Cert    │
                          └──┬──────┬───┘
                             │      │
                    ┌────────▼┐    ┌▼────────┐
                    │  EC2-1  │    │  EC2-2  │
                    │ (AZ-a)  │    │ (AZ-b)  │
                    │ Nginx   │    │ Nginx   │
                    │ Gunicorn│    │ Gunicorn│
                    └────┬────┘    └────┬────┘
                         │              │
                    ┌────▼──────────────▼────┐
                    │    RDS PostgreSQL      │
                    │    (Multi-AZ)          │
                    │    Private Subnet      │
                    └───────────────────────-┘

    ┌───────────┐   ┌──────────────┐   ┌──────────────┐
    │    S3     │   │  CloudWatch  │   │   Secrets    │
    │ Artifacts │   │ Logs/Alarms  │   │   Manager    │
    │ Uploads   │   │  Dashboards  │   │              │
    └───────────┘   └──────────────┘   └──────────────┘
```

### Component Details

| Component | Configuration |
|-----------|---------------|
| **VPC** | 2 public subnets (ALB), 2 private subnets (EC2, RDS), NAT Gateway for outbound |
| **EC2** | Ubuntu LTS, t3.medium, encrypted EBS, IMDSv2 required, SSM agent installed |
| **RDS PostgreSQL** | db.t3.medium, Multi-AZ, encrypted storage, automated backups (7 days), TLS connections |
| **ALB** | Internet-facing, HTTPS listener (ACM cert), HTTP→HTTPS redirect, health check on `/health/live/` |
| **Route 53** | A-record alias pointing to ALB |
| **S3** | Private encrypted buckets: (1) deployment artifacts, (2) user uploads; versioning + lifecycle rules |
| **IAM** | EC2 instance role (read secrets, write logs), Deployment role (S3, SSM), GitHub OIDC provider |
| **Security Groups** | ALB: 443 from internet; EC2: 80 from ALB SG only; RDS: 5432 from EC2 SG only |
| **CloudWatch** | Application logs, Nginx logs, host metrics (CPU, memory, disk), alarms → SNS → Slack |
| **CloudTrail** | API audit logging enabled for the account |
| **Backups** | RDS automated backups + pre-migration snapshots; S3 versioning for uploads |

### Security Group Rules

| Security Group | Direction | Port | Source/Destination |
|---------------|-----------|------|--------------------|
| `sg-alb` | Inbound | 443 | `0.0.0.0/0` (or VPN CIDR) |
| `sg-alb` | Inbound | 80 | `0.0.0.0/0` (redirect only) |
| `sg-ec2` | Inbound | 80 | `sg-alb` |
| `sg-rds` | Inbound | 5432 | `sg-ec2` |

### Monitoring and Alerts

| Metric | Threshold | Action |
|--------|-----------|--------|
| ALB 5xx error rate | > 5% for 5 min | Alert → investigate deployment or app errors |
| ALB unhealthy targets | > 0 for 3 min | Alert → check EC2 instance health |
| EC2 CPU utilization | > 80% for 10 min | Alert → consider scaling or optimization |
| RDS CPU utilization | > 70% for 10 min | Alert → query optimization or instance upgrade |
| RDS free storage | < 5 GB | Alert → increase storage or clean up |
| RDS connections | > 80% of max | Alert → connection pooling or instance upgrade |
| Disk usage (EC2) | > 85% | Alert → clean old releases, rotate logs |

---

## File Index

| File | Purpose |
|------|---------|
| `manage.py` | Django management entry point |
| `requirements.txt` | Pinned Python dependencies |
| `config/__init__.py` | Python package init |
| `config/settings.py` | Django settings (env-var driven) |
| `config/urls.py` | URL routing with health endpoints |
| `config/wsgi.py` | WSGI application for Gunicorn |
| `config/health.py` | Health-check endpoint code (Part 5) |
| `ops/platform.service` | Systemd unit file for Gunicorn |
| `ops/platform-nginx.conf` | Nginx reverse proxy configuration |
| `ops/deploy.sh` | Server-side deployment script with rollback |
| `.github/workflows/deploy.yml` | GitHub Actions CI/CD pipeline |

---

> **Note:** This submission contains sample configurations for demonstration. No real credentials, access keys, or confidential information are included. All infrastructure identifiers (instance IDs, endpoints, hostnames) are placeholders that must be replaced before execution.
