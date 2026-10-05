# Platform Deployment — Cloud DevOps Engineer Assignment

This repository contains the complete solution for the Platform Engineer Technical Assignment.

## Repository Structure

```
platform-deployment/
├── SOLUTION.md                         # Complete written solution (all 6 parts)
├── README.md                           # This file
├── manage.py                           # Django management command
├── requirements.txt                    # Pinned Python dependencies
├── config/
│   ├── __init__.py
│   ├── settings.py                     # Django settings (env-var driven, production-ready)
│   ├── urls.py                         # URL routing with health endpoints
│   ├── wsgi.py                         # WSGI entry point for Gunicorn
│   └── health.py                       # Health-check endpoint (Part 5)
├── ops/
│   ├── platform.service                # Systemd unit for Gunicorn
│   ├── platform-nginx.conf             # Nginx reverse proxy config
│   └── deploy.sh                       # Server-side deployment script with rollback
└── .github/
    └── workflows/
        └── deploy.yml                  # GitHub Actions CI/CD pipeline (Part 2)
```

## Assignment Parts Covered

| Part | Topic | Location |
|------|-------|----------|
| 1 | Deployment Approach | `SOLUTION.md` § Part 1 + `ops/` configs |
| 2 | CI/CD Pipeline | `.github/workflows/deploy.yml` |
| 3 | 502 Bad Gateway Investigation | `SOLUTION.md` § Part 3 |
| 4 | Security Review | `SOLUTION.md` § Part 4 |
| 5 | Health-Check Endpoint | `config/health.py` |
| 6 | AWS Architecture | `SOLUTION.md` § Part 6 |

## Quick Start (Local Development)

```bash
# Clone and enter the project
cd platform-deployment

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Set environment variables (for local dev)
export DJANGO_SECRET_KEY="local-dev-secret-key"
export DJANGO_DEBUG=True
export DJANGO_ALLOWED_HOSTS="localhost,127.0.0.1"
export DB_HOST=localhost
export DB_NAME=platform
export DB_USER=platform_app
export DB_PASSWORD=your_local_password
export DB_SSLMODE=disable

# Run migrations and start development server
python manage.py migrate
python manage.py runserver
```

## Important Note

This repository contains **sample configurations for demonstration purposes only**. No real credentials, access keys, or confidential information are included. All infrastructure identifiers must be replaced before execution.
