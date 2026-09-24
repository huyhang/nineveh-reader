#!/usr/bin/env python3
"""Saves real Nineveh responses as fixtures for the package's contract tests.

Only GET requests, so pointing it at a library people read from changes
nothing. The account needs read access to at least one library; credentials
come from the environment:

    NINEVEH_USER=reader NINEVEH_PASSWORD=... Scripts/capture-api-fixtures.py

NINEVEH_URL defaults to http://127.0.0.1:8081. The fixtures hold the titles
in that library, so capture from one you are happy to publish with the code.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
RESPONSES = REPOSITORY_ROOT / "Packages" / "NinevehReaderKit" / "Contract" / "responses"
# Enough to find a series with metadata and a volume with progress, without
# walking a large library.
MAXIMUM_PROBES = 20


class Server:
    def __init__(self, url: str, username: str, password: str):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.authorization = f"Basic {token}"

    def get(self, path: str, query: dict[str, str] | None = None, *, signed=True):
        """The decoded body, or None for a 404."""
        target = self.url + path
        if query:
            target += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(target, method="GET")
        if signed:
            request.add_header("Authorization", self.authorization)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise SystemExit(f"GET {target} answered {error.code}: {error.read()[:200]!r}")


def query_value(href: str, name: str) -> str | None:
    values = urllib.parse.parse_qs(urllib.parse.urlsplit(href).query).get(name)
    return values[0] if values else None


def publication_id(publication: dict) -> str | None:
    """The path segment after `publications`, as the reader takes it."""
    for link in publication.get("links", []) + publication.get("images", []):
        parts = urllib.parse.urlsplit(link["href"]).path.split("/")
        if "publications" in parts[:-1]:
            return urllib.parse.unquote(parts[parts.index("publications") + 1])
    return None


def series_id(publication: dict) -> str | None:
    series = publication["metadata"].get("belongsTo", {}).get("series") or [{}]
    identifier = series[0].get("identifier") or ""
    return identifier.removeprefix("urn:uuid:") or None


def main() -> None:
    username = os.environ.get("NINEVEH_USER")
    password = os.environ.get("NINEVEH_PASSWORD")
    if not username or not password:
        raise SystemExit("Set NINEVEH_USER and NINEVEH_PASSWORD.")
    server = Server(os.environ.get("NINEVEH_URL", "http://127.0.0.1:8081"), username, password)
    captured: list[tuple[str, str]] = []

    def save(name: str, body: object, request: str) -> None:
        text = json.dumps(body, indent=2, ensure_ascii=False) + "\n"
        (RESPONSES / name).write_text(text, encoding="utf-8")
        captured.append((name, request))

    RESPONSES.mkdir(parents=True, exist_ok=True)
    for stale in RESPONSES.glob("*.json"):
        stale.unlink()

    save(
        "authentication.json",
        server.get("/opds/v2/authentication.json", signed=False),
        "GET /opds/v2/authentication.json",
    )
    save("me.json", server.get("/api/v1/auth/me"), "GET /api/v1/auth/me")
    catalog = server.get("/opds/v2/catalog.json")
    save("catalog.json", catalog, "GET /opds/v2/catalog.json")

    libraries = [
        name for link in catalog["navigation"] if (name := query_value(link["href"], "library"))
    ]
    if not libraries:
        raise SystemExit("The catalog lists no library this account can read.")
    library = libraries[0]
    navigation = server.get("/opds/v2/navigation.json", {"library": library})
    save("navigation.json", navigation, f"GET /opds/v2/navigation.json?library={library}")

    # The first shelf whose volumes belong to a series, so the series fixture
    # comes from the same page as the volumes that point at it.
    shelves = []
    for link in navigation["navigation"]:
        category = query_value(link["href"], "category")
        if not category:
            continue
        feed = server.get("/opds/v2/publications.json", {"library": library, "category": category})
        shelves.append((category, feed))
        if any(map(series_id, feed["publications"])):
            break
    stocked = [shelf for shelf in shelves if shelf[1]["publications"]]
    if not stocked:
        raise SystemExit(f"No shelf in {library} lists a publication.")
    category, feed = stocked[-1]
    save(
        "publications.json",
        feed,
        f"GET /opds/v2/publications.json?library={library}&category={category}",
    )
    publications = feed["publications"][:MAXIMUM_PROBES]

    # Prefer a series with provider metadata: it exercises the most decoding.
    details = []
    for identifier in dict.fromkeys(filter(None, map(series_id, publications))):
        detail = server.get(f"/api/v1/series/{identifier}")
        if detail is None:
            continue
        details.append((identifier, detail))
        if detail.get("metadata"):
            break
    if details:
        identifier, detail = details[-1]
        save("series.json", detail, f"GET /api/v1/series/{identifier}")

    first = publication_id(publications[0])
    save(
        "pages.json",
        server.get(f"/api/v1/publications/{first}/pages"),
        f"GET /api/v1/publications/{first}/pages",
    )

    for identifier in filter(None, map(publication_id, publications)):
        position = server.get(f"/api/v1/publications/{identifier}/progress")
        if position is not None:
            save("progress.json", position, f"GET /api/v1/publications/{identifier}/progress")
            break

    contract = server.get("/openapi.json") or {}
    width = max(len(name) for name, _ in captured)
    lines = [
        f"server:   {server.url}",
        f"version:  {contract.get('info', {}).get('version', 'unknown')}",
        f"taken:    {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
        *(f"{name.ljust(width)}  {request}" for name, request in captured),
    ]
    (RESPONSES / "CAPTURED").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    missing = {"series.json", "progress.json"} - {name for name, _ in captured}
    for name in sorted(missing):
        print(f"No {name}: nothing in the first {MAXIMUM_PROBES} volumes has one.", file=sys.stderr)


if __name__ == "__main__":
    main()
