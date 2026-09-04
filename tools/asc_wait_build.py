#!/usr/bin/env python3
"""Block until an uploaded build finishes processing on App Store Connect, so it
can be attached to a version. Usage:

    asc_wait_build.py <bundle-id> <build-number> [timeout-seconds]

Credentials come from env (same as asc_listing.py): ASC_KEY_PATH, ASC_KEY_ID,
ASC_ISSUER_ID (falling back to ~/private_keys). Exits 0 when the build reaches
processingState VALID, non-zero on timeout or error.
"""
import glob
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
PRIV = Path.home() / "private_keys"


def token() -> str:
    key_path = os.environ.get("ASC_KEY_PATH") or (glob.glob(str(PRIV / "AuthKey_*.p8")) or [None])[0]
    if not key_path:
        sys.exit("no App Store Connect key: set ASC_KEY_PATH")
    key_id = os.environ.get("ASC_KEY_ID") or Path(key_path).stem.split("_", 1)[1]
    issuer = os.environ.get("ASC_ISSUER_ID") or (PRIV / "issuer").read_text().strip()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        Path(key_path).read_text(),
        algorithm="ES256",
        headers={"kid": key_id},
    )


def get(session, path, **params):
    r = session.get(f"{API}{path}", params=params, timeout=60)
    r.raise_for_status()
    return r.json()


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    bundle_id, build_number = sys.argv[1], sys.argv[2]
    timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 1500

    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {token()}"

    apps = get(s, "/apps", **{"filter[bundleId]": bundle_id})["data"]
    if not apps:
        sys.exit(f"no app with bundle id {bundle_id}")
    app_id = apps[0]["id"]

    deadline = time.time() + timeout
    while time.time() < deadline:
        builds = get(s, "/builds", **{"filter[app]": app_id, "filter[version]": build_number})["data"]
        if builds:
            state = builds[0]["attributes"].get("processingState")
            print(f"build {build_number}: {state}", flush=True)
            if state == "VALID":
                return 0
            if state in ("INVALID", "FAILED"):
                sys.exit(f"build {build_number} processing {state}")
        else:
            print(f"build {build_number}: not visible yet", flush=True)
        time.sleep(30)
    sys.exit(f"timed out after {timeout}s waiting for build {build_number} to process")


if __name__ == "__main__":
    raise SystemExit(main())
