"""
URL configuration for the internal platform.
"""

from django.contrib import admin
from django.urls import path

from .health import live, ready

urlpatterns = [
    path("admin/", admin.site.urls),

    # Health-check endpoints (no authentication required)
    path("health/live/", live, name="health-live"),
    path("health/ready/", ready, name="health-ready"),
]
