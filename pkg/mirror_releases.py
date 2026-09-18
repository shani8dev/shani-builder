#!/usr/bin/env python3
"""Mirror shani-builder publish artifacts to a GitHub Release.

Invoked by ``mirror_releases()`` in pkg-builder.sh after commit_and_push.
Uses only the standard library (urllib) — the builder image has no `requests`
or `gh` CLI. The GitHub token is read from the SHANI_GH_TOKEN environment
variable (never argv), and the target repo from SHANI_GH_REPO
("<owner>/<repo>"). argv[1] is the release tag; argv[2..] are artifact paths.

This is capability (b): upload-side publish extension. It does NOT touch the
package-database signing flow — signing happens in pkg-builder.sh; this only
mirrors already-signed artifacts as GitHub Release assets.
"""

from __future__ import annotations

import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request

GITHUB_API = "https://api.github.com"


def _repo() -> str:
    repo = os.environ.get("SHANI_GH_REPO", "").strip()
    if not repo or "/" not in repo:
        sys.stderr.write(
            "SHANI_GH_REPO must be '<owner>/<repo>' (e.g. shani8dev/shanios-releases)\n"
        )
        sys.exit(2)
    return repo


def _token() -> str:
    tok = os.environ.get("SHANI_GH_TOKEN", "").strip()
    if not tok:
        sys.stderr.write("SHANI_GH_TOKEN is required when mirroring releases\n")
        sys.exit(2)
    return tok


def _hdr(token: str, content_type: str | None = None) -> dict[str, str]:
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if content_type:
        headers["Content-Type"] = content_type
    return headers


def _api(repo: str, token: str, method: str, path: str,
         body: bytes | None = None) -> bytes:
    url = f"{GITHUB_API}/repos/{repo}{path}"
    req = urllib.request.Request(
        url, data=body, method=method, headers=_hdr(token, None) if body is None else _hdr(token, "application/json")
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310 (trusted GH API)
            return resp.read()
    except urllib.error.HTTPError as exc:
        sys.stderr.write(f"GitHub API {method} {path} -> HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')}\n")
        sys.exit(exc.code)


def create_or_get_release(repo: str, token: str, tag: str) -> dict:
    """Find an existing release for TAG, or create a draft release for it."""
    # Try GET first (idempotent across re-runs).
    try:
        raw = _api(repo, token, "GET", f"/releases/tags/{urllib.request.quote(tag, safe='')}")
        release = json.loads(raw)
        if isinstance(release, dict) and "upload_url" in release:
            return release
    except SystemExit:
        # 404 → no existing release, fall through to create.
        if sys.exc_info()[1] and getattr(sys.exc_info()[1], "code", 0) != 404:
            raise

    body = json.dumps(
        {
            "tag_name": tag,
            "name": f"Shani builder artifacts — {tag}",
            "draft": True,
            "generate_release_notes": False,
        }
    ).encode("utf-8")
    raw = _api(repo, token, "POST", "/releases", body)
    return json.loads(raw)


def upload_asset(release: dict, token: str, path: str) -> str:
    """Upload one file as a release asset via the release's upload_url."""
    upload_url = release.get("upload_url", "")
    if not upload_url:
        sys.stderr.write("release has no upload_url\n")
        sys.exit(3)
    name = os.path.basename(path)
    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    with open(path, "rb") as fh:
        data = fh.read()

    # upload_url contains a trailing {?name,label}; strip the template.
    base = upload_url.split("{")[0]
    url = f"{base}?name={urllib.request.quote(name, safe='')}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": ctype,
    }
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:  # noqa: S310 (trusted GH)
            return str(resp.getcode())
    except urllib.error.HTTPError as exc:
        sys.stderr.write(
            f"upload {name} -> HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')}\n"
        )
        sys.exit(exc.code)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(f"usage: {argv[0]} <tag> <file>...\n")
        return 2
    tag = argv[1]
    files = argv[2:]
    missing = [f for f in files if not os.path.isfile(f)]
    if missing:
        sys.stderr.write(f"missing artifact files: {missing}\n")
        return 2

    repo, token = _repo(), _token()
    release = create_or_get_release(repo, token, tag)
    for path in files:
        code = upload_asset(release, token, path)
        print(f"uploaded {os.path.basename(path)} -> HTTP {code}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
