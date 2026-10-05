"""
Health-check endpoints for the internal platform.

/health/live/   – Returns 200 if the application process is running.
/health/ready/  – Returns 200 if the application can reach the database;
                  503 otherwise.

These endpoints are used by:
  - ALB target-group health checks (liveness)
  - Deployment verification scripts (readiness)
  - Monitoring and alerting (both)
"""

import logging

from django.db import DatabaseError, connection
from django.http import JsonResponse
from django.views.decorators.http import require_GET

logger = logging.getLogger(__name__)


@require_GET
def live(request):
    """
    Liveness probe – confirms the WSGI process is responding.

    Always returns HTTP 200 with a minimal JSON body.  The ALB health
    check should target this endpoint.
    """
    return JsonResponse({"status": "ok"})


@require_GET
def ready(request):
    """
    Readiness probe – confirms the application can execute a query
    against the configured database.

    Returns HTTP 200 when the database is reachable, HTTP 503 otherwise.
    The response never exposes connection strings or exception details.
    """
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except DatabaseError:
        logger.exception("Readiness database check failed")
        return JsonResponse(
            {"status": "unavailable", "database": "unreachable"},
            status=503,
        )
    return JsonResponse({"status": "ok", "database": "ok"})
