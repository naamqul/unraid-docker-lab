#!/usr/bin/env python3
"""Enroll Forge in Beszel without exposing credentials or agent secrets."""

import getpass
import json
import os
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

BASE = "https://beszel.arc.home.arpa"
NAME = "Forge"
HOST = "192.168.50.179"
PORT = "45876"
SECRET_DIR = Path("/etc/beszel-agent")
KEY_PATH = SECRET_DIR / "key"
TOKEN_PATH = SECRET_DIR / "token"

os.umask(0o077)


class ApiError(RuntimeError):
    """Beszel enrollment failure with a deliberately non-sensitive message."""


def api(path, method="GET", payload=None, auth=None):
    headers = {"Accept": "application/json"}
    body = None
    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    if auth:
        headers["Authorization"] = auth
    request = urllib.request.Request(
        BASE + path, data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(
            request, timeout=20, context=ssl.create_default_context()
        ) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        exc.read()
        endpoint = path.split("?", 1)[0]
        raise ApiError(f"{method} {endpoint} failed (HTTP {exc.code})") from None
    except urllib.error.URLError:
        endpoint = path.split("?", 1)[0]
        raise ApiError(
            f"{method} {endpoint} failed (connection/TLS error)"
        ) from None


def stage(path, value):
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(value.rstrip("\n") + "\n")
            output.flush()
            os.fsync(output.fileno())
        return Path(temporary)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        Path(temporary).unlink(missing_ok=True)
        raise


def main():
    if os.geteuid() != 0:
        raise ApiError("Run this helper with sudo")

    identity = getpass.getpass("Beszel email (hidden): ").strip()
    password = getpass.getpass("Beszel password (hidden): ")
    system_id = None
    jwt = None
    temporary_key = None
    temporary_token = None
    committed = []

    try:
        auth = api(
            "/api/collections/users/auth-with-password",
            "POST",
            {"identity": identity, "password": password},
        )
        jwt = auth.get("token", "")
        user = auth.get("record") or {}
        if not jwt or user.get("role") not in ("admin", "user"):
            raise ApiError(
                "Authentication did not return a writable normal-user session"
            )
        del password, identity, auth

        info = api("/api/beszel/info", auth=jwt)
        public_key = info.get("key", "")
        if info.get("v") != "0.18.7" or not public_key.startswith(
            "ssh-ed25519 "
        ):
            raise ApiError("Unexpected Hub version or public-key format")

        query = urllib.parse.urlencode(
            {
                "filter": 'name = "Forge"',
                "fields": "id,name,host,status",
                "perPage": "1",
            }
        )
        existing = api(
            f"/api/collections/systems/records?{query}", auth=jwt
        )
        if existing.get("items"):
            raise ApiError("A visible Forge system already exists")
        if KEY_PATH.exists() or TOKEN_PATH.exists():
            raise ApiError("An agent secret file already exists")

        agent_token = str(uuid.uuid4())
        SECRET_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(SECRET_DIR, 0o700)
        temporary_key = stage(KEY_PATH, public_key)
        temporary_token = stage(TOKEN_PATH, agent_token)

        system = api(
            "/api/collections/systems/records",
            "POST",
            {
                "name": NAME,
                "host": HOST,
                "port": PORT,
                "users": user["id"],
            },
            jwt,
        )
        system_id = system.get("id")
        if not system_id:
            raise ApiError("System creation returned no ID")

        api(
            "/api/collections/fingerprints/records",
            "POST",
            {"system": system_id, "token": agent_token},
            jwt,
        )

        os.replace(temporary_key, KEY_PATH)
        temporary_key = None
        committed.append(KEY_PATH)
        os.replace(temporary_token, TOKEN_PATH)
        temporary_token = None
        committed.append(TOKEN_PATH)
        print(
            f"Forge registered as Beszel system {system_id}; "
            "root-only agent credentials were stored successfully."
        )
    except Exception:
        for path in (temporary_key, temporary_token):
            if path:
                path.unlink(missing_ok=True)
        for path in committed:
            path.unlink(missing_ok=True)
        if system_id and jwt:
            try:
                api(
                    f"/api/collections/systems/records/{system_id}",
                    "DELETE",
                    auth=jwt,
                )
            except Exception:
                print(
                    "WARNING: enrollment rollback failed; inspect the "
                    "Forge record manually.",
                    file=sys.stderr,
                )
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
