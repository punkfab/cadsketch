#!/usr/bin/env python3
"""Populate an App Store Connect listing from a directory of text files.

    asc_listing.py --bundle-id com.x.y --dir ios/appstore --version 1.0.0 \
                   [--build 1756...] [--dry-run] [--no-screenshots] [--locale en-US]

<dir>/metadata/<field>.txt : name subtitle description keywords promotional_text
                             whats_new support_url marketing_url privacy_policy_url
                             copyright primary_category secondary_category review_notes
<dir>/screenshots/<device>/*.png : device = ipad-13 | iphone-6.9 | iphone-6.7 |
                             iphone-6.5 | iphone-6.1 | iphone-5.5 | ipad-12.9-2nd
                             (or a raw screenshotDisplayType); files sorted by name.
Review contact from --contact-env (default ~/private_keys/asc-review-contact.env:
REVIEW_FIRST_NAME, REVIEW_LAST_NAME, REVIEW_PHONE, REVIEW_EMAIL — never in a repo).  Auth is the App Store
Connect API key on disk: ASC_KEY_PATH (default: the single AuthKey_*.p8 in
~/private_keys; key id from its name) and ASC_ISSUER_ID (default: the
~/private_keys/issuer file).  The key is read to sign JWTs and never printed.

What it sets: app name / subtitle / privacy URL / categories / age rating
(App Information), version copyright + manual release, en-US description /
keywords / promo text / URLs / What's New, review contact + notes, the iPad
screenshot sets, Free price + worldwide availability, and optionally the
build.  Left for the web UI: the App Privacy questionnaire and Submit for Review.

Needs: pip install pyjwt cryptography requests
"""
import argparse, glob, hashlib, json, os, sys, time
from pathlib import Path

import jwt, requests

API = "https://api.appstoreconnect.apple.com/v1"
PRIV = Path.home() / "private_keys"
# Filled from the command line in main().
HERE: Path = Path("."); BUNDLE_ID = ""; LOCALE = "en-US"; CONTACT_ENV = PRIV / "asc-review-contact.env"
# Screenshot folder name → App Store Connect display type (pixel sizes accepted).
DEVICES = {
    "ipad-13":       "APP_IPAD_PRO_3GEN_129",  # 2064x2752 / 2048x2732 (covers all iPads)
    "ipad-12.9-2nd": "APP_IPAD_PRO_129",       # 2048x2732
    "iphone-6.9":    "APP_IPHONE_67",          # 1320x2868 / 1290x2796 (6.9" and 6.7")
    "iphone-6.7":    "APP_IPHONE_67",
    "iphone-6.5":    "APP_IPHONE_65",          # 1284x2778 / 1242x2688
    "iphone-6.1":    "APP_IPHONE_61",          # 1179x2556 / 1170x2532
    "iphone-5.5":    "APP_IPHONE_55",          # 1242x2208
}

# ── auth ──────────────────────────────────────────────────────────────────────
def token():
    key_path = os.environ.get("ASC_KEY_PATH") or (glob.glob(str(PRIV / "AuthKey_*.p8")) or [None])[0]
    if not key_path: sys.exit("no App Store Connect key: set ASC_KEY_PATH")
    key_id = os.environ.get("ASC_KEY_ID") or Path(key_path).stem.split("_", 1)[1]
    issuer = os.environ.get("ASC_ISSUER_ID") or (PRIV / "issuer").read_text().strip()
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
                      Path(key_path).read_text(), algorithm="ES256", headers={"kid": key_id})

class Client:
    def __init__(self, dry):
        self.dry = dry
        self.s = requests.Session()
        self.s.headers["Authorization"] = f"Bearer {token()}"
    def _call(self, method, path, **kw):
        url = path if path.startswith("http") else API + path
        r = self.s.request(method, url, timeout=60, **kw)
        if r.status_code >= 400:
            try: err = json.dumps(r.json().get("errors"), indent=1)
            except Exception: err = r.text[:500]
            raise RuntimeError(f"{method} {path} → {r.status_code}\n{err}")
        return r.json() if r.content and r.headers.get("content-type", "").startswith("application/") else {}
    def get(self, path, **params):
        return self._call("GET", path, params=params)
    def write(self, method, path, body):
        """POST/PATCH/DELETE — skipped (and printed) in dry-run."""
        if self.dry:
            print(f"  [dry] {method} {path} {json.dumps(body)[:160] if body else ''}")
            return {"data": {"id": "dry", "attributes": {}}}
        return self._call(method, path, json=body) if body is not None else self._call(method, path)

def attrs(kind, id_, a, rel=None):
    d = {"type": kind, "attributes": a}
    if id_: d["id"] = id_
    if rel: d["relationships"] = rel
    return {"data": d}

def read(name):
    return (HERE / "metadata" / f"{name}.txt").read_text().strip()

# ── steps ─────────────────────────────────────────────────────────────────────
def find_app(c):
    apps = c.get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps: sys.exit(f"no app with bundle id {BUNDLE_ID} on this team")
    a = apps[0]; print(f"app: {a['attributes']['name']} ({a['id']})")
    return a["id"]

def app_info(c, app_id):
    """App Information: name, subtitle, privacy URL, categories, age rating."""
    infos = c.get(f"/apps/{app_id}/appInfos")["data"]
    editable = [i for i in infos if i["attributes"].get("appStoreState") in
                ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", None)]
    info = (editable or infos)[0]; iid = info["id"]
    state = info["attributes"].get("appStoreState")
    print(f"appInfo {iid} state={state}")
    if state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE"):
        print("  app is submitted/live — App Information left untouched (edit it for the next version)"); return
    c.write("PATCH", f"/appInfos/{iid}", {"data": {"type": "appInfos", "id": iid, "relationships": {
        "primaryCategory":   {"data": {"type": "appCategories", "id": read("primary_category")}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": read("secondary_category")}},
    }}})
    locs = c.get(f"/appInfos/{iid}/appInfoLocalizations")["data"]
    want = {"name": read("name"), "subtitle": read("subtitle"), "privacyPolicyUrl": read("privacy_policy_url")}
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    if loc: c.write("PATCH", f"/appInfoLocalizations/{loc['id']}", attrs("appInfoLocalizations", loc["id"], want))
    else:   c.write("POST", "/appInfoLocalizations", attrs("appInfoLocalizations", None, {**want, "locale": LOCALE},
                    {"appInfo": {"data": {"type": "appInfos", "id": iid}}}))
    print(f"  name/subtitle/privacy URL ({'updated' if loc else 'created'} {LOCALE})")
    age_rating(c, iid)

NONE_FIELDS = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "horrorOrFearThemes",
               "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
               "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy",
               "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic", "gunsOrOtherWeapons"]
FALSE_FIELDS = ["gambling", "unrestrictedWebAccess", "lootBox", "advertising", "messagingAndChat",
                "userGeneratedContent", "parentalControls", "ageAssurance",
                "healthOrWellnessTopics", "socialMedia", "socialMediaAgeRestricted"]

def age_rating(c, iid):
    """Every questionnaire answer is None/false → 4+.  Only touches attributes
    the API actually exposes (Apple adds questions over time); reports any it
    still leaves unanswered."""
    d = c.get(f"/appInfos/{iid}/ageRatingDeclaration")["data"]
    cur = d["attributes"]; body = {}
    for k in NONE_FIELDS:
        if k in cur and cur[k] != "NONE": body[k] = "NONE"
    for k in FALSE_FIELDS:
        if k in cur and cur[k] is not False: body[k] = False
    if body: c.write("PATCH", f"/ageRatingDeclarations/{d['id']}", attrs("ageRatingDeclarations", d["id"], body))
    left = [k for k, v in cur.items() if v is None and k not in body and k not in ("kidsAgeBand", "seventeenPlus", "developerAgeRatingInfoUrl", "ageRatingOverride", "koreaAgeRatingOverride")]
    print(f"  age rating: set {len(body)} answers" + (f"; still unanswered in UI: {left}" if left else ""))

def version(c, app_id, ver):
    vs = c.get(f"/apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS"})["data"]
    open_ = [v for v in vs if v["attributes"]["appStoreState"] in
             ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")]
    body = {"copyright": read("copyright"), "releaseType": "MANUAL"}
    if open_:
        v = open_[0]; vid = v["id"]
        print(f"version {v['attributes']['versionString']} ({vid}) state={v['attributes']['appStoreState']}")
        if v["attributes"]["versionString"] != ver: body["versionString"] = ver
        c.write("PATCH", f"/appStoreVersions/{vid}", attrs("appStoreVersions", vid, body))
    else:
        r = c.write("POST", "/appStoreVersions", attrs("appStoreVersions", None, {**body, "platform": "IOS", "versionString": ver},
                    {"app": {"data": {"type": "apps", "id": app_id}}}))
        vid = r["data"]["id"]; print(f"version {ver} created ({vid})")
    return vid

def version_localization(c, vid):
    locs = c.get(f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
    want = {"description": read("description"), "keywords": read("keywords"),
            "promotionalText": read("promotional_text"), "supportUrl": read("support_url"),
            "marketingUrl": read("marketing_url"), "whatsNew": read("whats_new")}
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    def put(w):
        if loc: return c.write("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", attrs("appStoreVersionLocalizations", loc["id"], w))
        return c.write("POST", "/appStoreVersionLocalizations", attrs("appStoreVersionLocalizations", None, {**w, "locale": LOCALE},
                       {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}))
    try:
        r = put(want)
    except RuntimeError as e:
        if "whatsNew" not in str(e): raise
        # A first version has no "What's New"; App Store Connect rejects it.
        want.pop("whatsNew"); r = put(want); print("  (first version: What's New not applicable, skipped)")
    lid = loc["id"] if loc else r["data"]["id"]
    print(f"  description/keywords/promo/URLs ({'updated' if loc else 'created'} {LOCALE})")
    return lid

def review_details(c, vid):
    env = CONTACT_ENV
    if not env.exists(): print(f"  review contact: {env} missing — skipped"); return
    kv = dict(l.split("=", 1) for l in env.read_text().splitlines() if "=" in l and not l.startswith("#"))
    want = {"contactFirstName": kv["REVIEW_FIRST_NAME"], "contactLastName": kv["REVIEW_LAST_NAME"],
            "contactPhone": kv["REVIEW_PHONE"], "contactEmail": kv["REVIEW_EMAIL"],
            "demoAccountRequired": False, "notes": read("review_notes")}
    try:
        cur = c.get(f"/appStoreVersions/{vid}/appStoreReviewDetail")["data"]
    except RuntimeError:
        cur = None
    if cur: c.write("PATCH", f"/appStoreReviewDetails/{cur['id']}", attrs("appStoreReviewDetails", cur["id"], want))
    else:   c.write("POST", "/appStoreReviewDetails", attrs("appStoreReviewDetails", None, want,
                    {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}))
    print("  review contact + notes set")

def screenshots(c, lid):
    root = HERE / "screenshots"
    dirs = sorted(d for d in root.iterdir() if d.is_dir()) if root.exists() else []
    if not dirs: print("  no screenshots/ folders — skipped"); return
    sets = c.get(f"/appStoreVersionLocalizations/{lid}/appScreenshotSets")["data"]
    for d in dirs:
        dtype = DEVICES.get(d.name, d.name if d.name.startswith("APP_") else None)
        if not dtype: print(f"  {d.name}: unknown device folder (see DEVICES) — skipped"); continue
        files = sorted(d.glob("*.png")) + sorted(d.glob("*.jpg"))
        if not files: continue
        st = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == dtype), None)
        if st:
            old = c.get(f"/appScreenshotSets/{st['id']}/appScreenshots")["data"]
            for o in old: c.write("DELETE", f"/appScreenshots/{o['id']}", None)
            if old: print(f"  {dtype}: removed {len(old)} existing")
            sid = st["id"]
        else:
            sid = c.write("POST", "/appScreenshotSets", attrs("appScreenshotSets", None, {"screenshotDisplayType": dtype},
                          {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}))["data"]["id"]
        ids = []
        for f in files:
            data = f.read_bytes()
            r = c.write("POST", "/appScreenshots", attrs("appScreenshots", None, {"fileName": f.name, "fileSize": len(data)},
                        {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}))
            if c.dry: print(f"  [dry] {dtype}: would upload {f.name} ({len(data)} bytes)"); continue
            shot = r["data"]; ids.append(shot["id"])
            for op in shot["attributes"]["uploadOperations"]:
                chunk = data[op["offset"]: op["offset"] + op["length"]]
                hdrs = {h["name"]: h["value"] for h in op["requestHeaders"]}
                rr = requests.request(op["method"], op["url"], data=chunk, headers=hdrs, timeout=120); rr.raise_for_status()
            c.write("PATCH", f"/appScreenshots/{shot['id']}", attrs("appScreenshots", shot["id"],
                    {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}))
            for _ in range(60):
                state = c.get(f"/appScreenshots/{shot['id']}")["data"]["attributes"]["assetDeliveryState"]["state"]
                if state in ("COMPLETE", "FAILED"): break
                time.sleep(2)
            print(f"  {dtype}: {f.name} {state}")
            if state == "FAILED": raise RuntimeError(f"{f.name} failed asset processing")
        if ids:
            c.write("PATCH", f"/appScreenshotSets/{sid}/relationships/appScreenshots",
                    {"data": [{"type": "appScreenshots", "id": i} for i in ids]})

def price_free(c, app_id):
    try:
        c.get(f"/apps/{app_id}/appPriceSchedule"); print("  price schedule exists — left alone"); return
    except RuntimeError: pass
    pts = c.get(f"/apps/{app_id}/appPricePoints", **{"filter[territory]": "USA", "limit": 5})["data"]
    free = next(p["id"] for p in pts if float(p["attributes"]["customerPrice"]) == 0.0)
    lid = "${free0}"   # inline-creation ids must look like ${...}
    c.write("POST", "/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
        "app": {"data": {"type": "apps", "id": app_id}},
        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
        "manualPrices": {"data": [{"type": "appPrices", "id": lid}]}}},
        "included": [{"type": "appPrices", "id": lid, "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free}}}}]})
    print("  price: Free (USA base, all territories follow)")

def availability_all(c, app_id):
    try:
        c.get(f"/apps/{app_id}/appAvailabilityV2"); print("  availability exists — left alone"); return
    except RuntimeError: pass
    terr = [t["id"] for t in c.get("/territories", limit=200)["data"]]
    inc = [{"type": "territoryAvailabilities", "id": "${t%d}" % i, "attributes": {"available": True},
            "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for i, t in enumerate(terr)]
    c.write("POST", "https://api.appstoreconnect.apple.com/v2/appAvailabilities",
            {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
                      "relationships": {"app": {"data": {"type": "apps", "id": app_id}},
                                        "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": x["id"]} for x in inc]}}},
             "included": inc})
    print(f"  availability: all {len(terr)} territories")

def attach_build(c, app_id, vid, build):
    bs = c.get("/builds", **{"filter[app]": app_id, "filter[version]": build, "sort": "-uploadedDate"})["data"]
    if not bs: sys.exit(f"build {build} not found (still processing?)")
    b = bs[0]; print(f"build {build}: {b['attributes']['processingState']}")
    c.write("PATCH", f"/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})
    print("  attached to version")

def main():
    global HERE, BUNDLE_ID, LOCALE, CONTACT_ENV
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--dir", required=True, help="folder holding metadata/ and screenshots/")
    ap.add_argument("--version", required=True, help="marketing version, e.g. 1.0.0 (must match the build's)")
    ap.add_argument("--build", help="build number to attach (must already be processed)")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--contact-env", default=str(PRIV / "asc-review-contact.env"))
    ap.add_argument("--dry-run", action="store_true", help="read everything, write nothing")
    ap.add_argument("--no-screenshots", action="store_true")
    ap.add_argument("--no-price", action="store_true", help="skip Free price + all-territory availability")
    a = ap.parse_args()
    HERE, BUNDLE_ID, LOCALE, CONTACT_ENV = Path(a.dir).resolve(), a.bundle_id, a.locale, Path(a.contact_env).expanduser()
    c = Client(a.dry_run)
    app_id = find_app(c)
    app_info(c, app_id)
    if not a.no_price: price_free(c, app_id); availability_all(c, app_id)
    vid = version(c, app_id, a.version)
    if vid == "dry": print("(dry run: version would be created; localization/review/screenshots skipped)"); return
    lid = version_localization(c, vid)
    review_details(c, vid)
    if not a.no_screenshots: screenshots(c, lid)
    if a.build: attach_build(c, app_id, vid, a.build)
    print("\nleft for the web UI: App Privacy questionnaire; Submit for Review.")

if __name__ == "__main__":
    try: main()
    except RuntimeError as e: sys.exit(f"error: {e}")
