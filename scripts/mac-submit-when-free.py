#!/usr/bin/env python3
"""Submit a Mac build as a new App Store version once no other Mac version is in review.
Usage (from localvoice/): python3 scripts/mac-submit-when-free.py 1.3.4 10 whats-new.txt
Exit 0 = submitted (or already submitted), 3 = not yet (try later), 1 = needs a human."""
import json, subprocess, sys

APP = "6795213062"
VERSION, BUILD, NOTES_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
BUSY = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PROCESSING_FOR_DISTRIBUTION"}
STUCK = {"REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}


def asc(method, path, body=None):
    out = subprocess.run(["python3", "scripts/asc.py", method, path] + ([json.dumps(body)] if body else []),
                         capture_output=True, text=True).stdout
    if out.startswith("HTTP"):
        raise RuntimeError(f"{method} {path}: {out[:600]}")
    return json.loads(out) if out.startswith("{") else {}


versions = asc("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=MAC_OS&limit=10"
                      "&fields[appStoreVersions]=versionString,appStoreState")["data"]
mine = next((v for v in versions if v["attributes"]["versionString"] == VERSION), None)
if mine and mine["attributes"]["appStoreState"] != "PREPARE_FOR_SUBMISSION":
    print(f"{VERSION} already {mine['attributes']['appStoreState']}")
    sys.exit(0)
others = {v["attributes"]["versionString"]: v["attributes"]["appStoreState"] for v in versions if v is not mine}
if any(s in STUCK for s in others.values()):
    print(f"another version needs attention: {others}")
    sys.exit(1)
if any(s in BUSY for s in others.values()):
    print(f"still busy: {others}")
    sys.exit(3)

build = asc("GET", f"/v1/builds?filter[app]={APP}&filter[version]={BUILD}&filter[preReleaseVersion.platform]=MAC_OS"
                   "&fields[builds]=processingState,usesNonExemptEncryption")["data"]
if not build or build[0]["attributes"]["processingState"] != "VALID":
    print(f"build {BUILD} not VALID yet")
    sys.exit(3)
build_id = build[0]["id"]
if build[0]["attributes"]["usesNonExemptEncryption"] is None:
    asc("PATCH", f"/v1/builds/{build_id}", {"data": {"type": "builds", "id": build_id,
        "attributes": {"usesNonExemptEncryption": False}}})

if not mine:
    mine = asc("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
        "attributes": {"platform": "MAC_OS", "versionString": VERSION, "releaseType": "AFTER_APPROVAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
vid = mine["id"]
asc("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": build_id}})

whats_new = open(NOTES_FILE).read().strip()
for loc in asc("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]:
    asc("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations",
        "id": loc["id"], "attributes": {"whatsNew": whats_new}}})

review_notes = open("marketing/mac-app-review-notes.txt").read().strip()
try:
    detail = asc("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
except RuntimeError:
    detail = None
if detail:
    asc("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails",
        "id": detail["id"], "attributes": {"notes": review_notes}}})
else:
    live = next(v for v in versions if v["attributes"]["appStoreState"] in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION"))
    contact = asc("GET", f"/v1/appStoreVersions/{live['id']}/appStoreReviewDetail")["data"]["attributes"]
    contact = {k: v for k, v in contact.items() if v is not None}
    contact["notes"] = review_notes
    asc("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": contact,
        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})

open_subs = asc("GET", f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=MAC_OS&filter[state]=READY_FOR_REVIEW")["data"]
sub = open_subs[0]["id"] if open_subs else asc("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
    "attributes": {"platform": "MAC_OS"}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]["id"]
asc("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems",
    "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub}},
                      "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
asc("PATCH", f"/v1/reviewSubmissions/{sub}", {"data": {"type": "reviewSubmissions", "id": sub,
    "attributes": {"submitted": True}}})
print(f"submitted {VERSION} ({BUILD}): version {vid}, submission {sub}")
