"""Read-only personal overview from the local Pi Dashboard service."""

import asyncio
import stat
import time
from pathlib import Path

import httpx


class PersonalBridge:
    def __init__(self, state: Path, base_url: str = "http://127.0.0.1:8648"):
        self.credential = state / "dashboard-service-token"
        self.base_url = base_url.rstrip("/")

    def token(self) -> str:
        try:
            info = self.credential.stat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("credential_permissions")
            value = self.credential.read_text().strip()
            if not value:
                raise ValueError("credential_missing")
            return value
        except FileNotFoundError:
            raise ValueError("credential_missing") from None

    async def fetch(self, path: str) -> dict:
        token = self.token()
        async with httpx.AsyncClient(timeout=8, trust_env=False, follow_redirects=False) as client:
            response = await client.get(
                self.base_url + path,
                headers={"Authorization": "Bearer " + token},
            )
        if response.status_code == 401:
            raise ValueError("upstream_auth_failed")
        if response.status_code == 403:
            raise ValueError("upstream_denied")
        if response.status_code >= 500:
            raise ValueError("upstream_unavailable")
        if response.status_code != 200:
            raise ValueError("upstream_error")
        try:
            data = response.json()
        except ValueError:
            raise ValueError("invalid_response") from None
        if not isinstance(data, dict):
            raise ValueError("invalid_response")
        return data

    async def source(self, path: str, projector):
        try:
            return projector(await self.fetch(path))
        except ValueError as exc:
            return {"available": False, "error_code": str(exc)}
        except httpx.TimeoutException:
            return {"available": False, "error_code": "upstream_timeout"}
        except httpx.HTTPError:
            return {"available": False, "error_code": "upstream_unavailable"}

    async def overview(self) -> dict:
        calendar, finance = await asyncio.gather(
            self.source("/api/v1/calendar", calendar_overview),
            self.source("/api/v1/finance", finance_overview),
        )
        return {
            "schema_version": 1,
            "generated_at": time.time(),
            "calendar": calendar,
            "finance": finance,
        }


def calendar_overview(data: dict) -> dict:
    if not data.get("available"):
        return {"available": False, "error_code": "source_unavailable"}
    items = data.get("items")
    if not isinstance(items, list):
        raise ValueError("invalid_response")
    events = []
    for event in items[:10]:
        if not isinstance(event, dict):
            continue
        events.append({
            "id": event.get("id"),
            "title": event.get("summary") or "未命名日程",
            "start": event.get("start"),
            "end": event.get("end"),
            "url": event.get("htmlLink"),
        })
    return {
        "available": True,
        "source": "Google Calendar",
        "updated_at": data.get("updated"),
        "coverage": {"scope": "configured_calendar_only", "days": 14},
        "items": events,
    }


def finance_overview(data: dict) -> dict:
    if not data.get("available"):
        return {"available": False, "error_code": "source_unavailable"}
    totals = data.get("totals")
    if not isinstance(totals, dict):
        raise ValueError("invalid_response")
    summary = {}
    for currency, row in totals.items():
        if not isinstance(row, dict):
            continue
        summary[currency] = {
            "income_minor": row.get("income"),
            "expense_minor": row.get("expense"),
            "today_expense_minor": row.get("today_expense"),
            "categories_minor": row.get("categories", {}),
        }
    return {
        "available": True,
        "source": "ezBookkeeping",
        "updated_at": data.get("updated"),
        "stale": bool(data.get("stale")),
        "month": data.get("month"),
        "month_start": data.get("month_start"),
        "month_end": data.get("month_end"),
        "month_transaction_count": data.get("month_transaction_count"),
        "coverage": data.get("coverage", "unknown"),
        "totals": summary,
    }
