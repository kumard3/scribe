"""Usage: python3 attach_mac_review.py <recording.mov>  (run from localvoice/). Re-encodes, attaches to the Mac review detail, updates notes."""
import json, subprocess, hashlib, os, sys, urllib.request
SCR = "marketing"
RID = "2fa9a059-99d1-4e8c-a268-5bdc5357df6d"
def asc(method, path, body=None):
    out = subprocess.run(["python3", "scripts/asc.py", method, path] + ([json.dumps(body)] if body else []), capture_output=True, text=True).stdout
    if not out.startswith("{") and out.strip() != "(empty)":
        sys.exit(f"{method} {path} failed: {out[:800]}")
    return json.loads(out) if out.startswith("{") else {}
src, dst = sys.argv[1], "/tmp/bolkit-mac-review-recording.mp4"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-vf", "scale=-2:1080,fps=30", "-c:v", "libx264", "-crf", "26",
                "-preset", "medium", "-pix_fmt", "yuv420p", "-an", "-movflags", "+faststart", dst], check=True)
data = open(dst, "rb").read(); print("encoded", len(data) // 1024, "KB")
r = asc("POST", "/v1/appStoreReviewAttachments", {"data": {"type": "appStoreReviewAttachments",
    "attributes": {"fileName": os.path.basename(dst), "fileSize": len(data)},
    "relationships": {"appStoreReviewDetail": {"data": {"type": "appStoreReviewDetails", "id": RID}}}}})
aid = r["data"]["id"]
for op in r["data"]["attributes"]["uploadOperations"]:
    urllib.request.urlopen(urllib.request.Request(op["url"], data=data[op["offset"]:op["offset"] + op["length"]],
        method=op["method"], headers={h["name"]: h["value"] for h in op["requestHeaders"]})).read()
asc("PATCH", f"/v1/appStoreReviewAttachments/{aid}", {"data": {"type": "appStoreReviewAttachments", "id": aid,
    "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
notes = open(os.path.join(SCR, "mac-app-review-notes.txt")).read().strip()
asc("PATCH", f"/v1/appStoreReviewDetails/{RID}", {"data": {"type": "appStoreReviewDetails", "id": RID, "attributes": {"notes": notes}}})
print("attached", aid, "and notes updated")
