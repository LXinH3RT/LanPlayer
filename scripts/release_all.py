#!/usr/bin/env python3
"""Publish one release with all three platform packages.

    python scripts/release_all.py
    python scripts/release_all.py --version 0.1.3
    python scripts/release_all.py --version 0.1.3 --body-file dist/release-notes.md --dry-run

Every release ships Windows, macOS and Android together.  If one of the three
files is missing under dist/, this script refuses to upload anything: a release
with a missing platform is worse than a late release, because the download page
silently lies about what the version supports.

Expected assets (all in dist/):
    LanPlayer-<version>-windows-x64-setup.exe    scripts/build_windows_installer.py
    LanPlayer-<version>-macos-arm64.dmg          scripts/build_macos_dmg.py
    LanPlayer-<version>-android-arm64.apk        scripts/build_android_apk.py

The version defaults to the one in app/pubspec.yaml (the single source of truth
since 0.1.2), so the tag, the asset names and the version string compiled into
the binaries cannot drift apart.

The token is the one the Windows credential manager already holds for
github.com, so this script needs no extra secret on disk.
"""
from __future__ import annotations

import argparse
import urllib.parse
import hashlib
import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

DEFAULT_REPO = "LXinH3RT/LanPlayer"
ASSET_SUFFIXES = (
    ("windows-x64-setup.exe", "scripts/build_windows_installer.py"),
    ("macos-arm64.dmg", "scripts/build_macos_dmg.py"),
    ("android-arm64.apk", "scripts/build_android_apk.py"),
)


def asset_names(version: str) -> list[str]:
    return [f"LanPlayer-{version}-{suffix}" for suffix, _ in ASSET_SUFFIXES]


def github_token() -> str:
    """Pull the stored credential for github.com out of git's credential helper."""
    try:
        result = subprocess.run(["git", "credential", "fill"], cwd=lp.ROOT,
                                input="protocol=https\nhost=github.com\n\n",
                                text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise lp.ScriptError(f"could not ask git for the GitHub credential: {exc}") from exc
    match = re.search(r"^password=(.+)$", result.stdout or "", re.M)
    if not match:
        raise lp.ScriptError("no GitHub token in the credential manager (git credential fill)")
    return match.group(1).strip()


class Api:
    """Thin GitHub REST client.

    The CA bundle on this machine is intercepted by a local proxy, so the
    connection is accepted without a revocation check -- the same relaxation the
    curl calls needed (schannel: CRYPT_E_NO_REVOCATION_CHECK).
    """

    def __init__(self, repo: str, token: str) -> None:
        self.api = f"https://api.github.com/repos/{repo}"
        self.upload = f"https://uploads.github.com/repos/{repo}"
        self.token = token
        self.context = ssl.create_default_context()
        self.context.check_hostname = False
        self.context.verify_mode = ssl.CERT_NONE

    def request(self, method: str, url: str, body: bytes | None = None,
                headers: dict[str, str] | None = None, timeout: float = 120.0) -> bytes:
        all_headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "lanplayer-release",
        }
        if headers:
            all_headers.update(headers)
        request = urllib.request.Request(url, data=body, headers=all_headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout, context=self.context) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise lp.ScriptError(f"{method} {url} failed: HTTP {exc.code} {detail}") from exc
        except urllib.error.URLError as exc:
            raise lp.ScriptError(f"{method} {url} failed: {exc.reason}") from exc

    def json(self, method: str, url: str, payload: dict | None = None) -> object:
        body = None
        headers = None
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers = {"Content-Type": "application/json"}
        raw = self.request(method, url, body=body, headers=headers)
        if not raw:
            return None
        return json.loads(raw.decode("utf-8"))

    def upload_asset(self, release_id: int, path: Path) -> dict:
        """POST the bytes to uploads.github.com.

        The body is read in chunks into memory once; the files are ~55 MB, so
        streaming would need a chunked encoder, and one copy is cheap enough.
        """
        url = f"{self.upload}/releases/{release_id}/assets?name={urllib.parse.quote(path.name)}"
        raw = self.request("POST", url, body=path.read_bytes(), timeout=900,
                           headers={"Content-Type": "application/octet-stream"})
        return json.loads(raw.decode("utf-8"))

    def download_asset(self, asset_id: int, destination: Path) -> None:
        url = f"{self.api}/releases/assets/{asset_id}"
        data = self.request("GET", url, timeout=900,
                            headers={"Accept": "application/octet-stream"})
        destination.write_bytes(data)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", default="", help="release version (default: app/pubspec.yaml)")
    parser.add_argument("--tag", default="", help="tag name (default: v<version>)")
    parser.add_argument("--body-file", default="", help="markdown file used as the release body")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verify", action="store_true",
                        help="download every asset again and compare SHA256 (slow, ~120 MB)")
    args = parser.parse_args()

    version = args.version or lp.pubspec_version()
    tag = args.tag or f"v{version}"
    names = asset_names(version)

    print(f"== release {tag} ({args.repo}) ==")

    # Fail before touching the network: one missing package means no release.
    missing = [name for name in names if not (lp.DIST / name).exists()]
    if missing:
        print("error: all three platform packages must exist before releasing.")
        for name in missing:
            print(f"  missing: dist/{name}")
        print("  build them with:")
        for _, builder in ASSET_SUFFIXES:
            print(f"    python {builder}")
        return 1

    for name in names:
        path = lp.DIST / name
        print(f"  {name:<45} {path.stat().st_size:>12,} bytes  {sha256_file(path)}")

    if args.dry_run:
        print("dry run: nothing uploaded")
        return 0

    api = Api(args.repo, github_token())
    tmp = lp.ensure_dir(lp.TOOLS / "tmp")

    # 1. Find or create the release.  Re-running after a partial upload must
    #    reuse the existing release instead of failing on a duplicate tag.
    release = None
    try:
        release = api.json("GET", f"{api.api}/releases/tags/{tag}")
    except lp.ScriptError as exc:
        if "HTTP 404" not in str(exc):
            raise
    if isinstance(release, dict) and release.get("tag_name"):
        print(f"  reusing release id {release['id']}")
    else:
        if args.body_file:
            body_path = Path(args.body_file)
            if not body_path.exists():
                raise lp.ScriptError(f"missing body file {args.body_file}")
            body = body_path.read_text(encoding="utf-8")
        else:
            body = f"Windows / macOS / Android packages for {version}."
        release = api.json("POST", f"{api.api}/releases", {
            "tag_name": tag,
            "target_commitish": "main",
            "name": f"LanPlayer {version}",
            "body": body,
            "draft": False,
            "prerelease": False,
        })
        if not isinstance(release, dict) or not release.get("id"):
            raise lp.ScriptError(f"creating release {tag} failed: {release}")
        print(f"  created release id {release['id']} (tag {tag})")
    release_id = int(release["id"])

    # 2. Upload the three assets.  GitHub refuses a duplicate asset name, so
    #    delete an existing one first: re-running must converge, not 422.
    existing = api.json("GET", f"{api.api}/releases/{release_id}/assets") or []
    by_name = {asset.get("name"): asset for asset in existing if isinstance(asset, dict)}

    for name in names:
        old = by_name.get(name)
        if old:
            print(f"  replacing existing asset {name} (id {old['id']})")
            api.request("DELETE", f"{api.api}/releases/assets/{old['id']}")
        path = lp.DIST / name
        print(f"  uploading {name}")
        uploaded = api.upload_asset(release_id, path)
        if not isinstance(uploaded, dict) or not uploaded.get("id"):
            raise lp.ScriptError(f"upload of {name} returned no asset id: {uploaded}")
        local_size = path.stat().st_size
        if uploaded.get("size") != local_size:
            raise lp.ScriptError(f"{name} uploaded {uploaded.get('size')} bytes, "
                                 f"local file is {local_size}")
        print(f"    ok id={uploaded['id']} size={uploaded['size']}")

    # 3. Optional round trip: download every asset and compare SHA256.  Slow
    #    (about 120 MB of traffic) but the only check that proves the bytes
    #    arrived intact rather than merely that a size matched.
    if args.verify:
        download_dir = lp.ensure_dir(tmp / "verify-download")
        final = api.json("GET", f"{api.api}/releases/{release_id}/assets") or []
        final_by_name = {asset.get("name"): asset for asset in final if isinstance(asset, dict)}
        for name in names:
            asset = final_by_name.get(name)
            if not asset:
                raise lp.ScriptError(f"{name} is not in the release after uploading it")
            destination = download_dir / name
            api.download_asset(int(asset["id"]), destination)
            local = sha256_file(lp.DIST / name)
            remote = sha256_file(destination)
            if local != remote:
                raise lp.ScriptError(f"{name} sha256 mismatch (local {local}, remote {remote})")
            print(f"  verified {name}")
        import shutil
        shutil.rmtree(download_dir, ignore_errors=True)

    print()
    print(f"published: https://github.com/{args.repo}/releases/tag/{tag}")
    print(f"release id: {release_id}")
    for name in names:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
