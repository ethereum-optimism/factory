#!/usr/bin/env python3
"""Download the APKs pinned by apko and melange lock files into an apko cache.

The request file is JSON:

    {
      "host": "apk.example.dev",
      "path_prefix": "/org/",
      "redirect_hosts": ["storage.example.net", "*.cdn.example.net"],
      "lockfiles": ["apko/app.lock.json", "melange/tool.lock.json"],
      "archs": ["x86_64"]
    }

Every non-local package URL and every remote repository index URL in the lock
files must be https on exactly the configured host, under the configured path
prefix. Every non-local package must carry a whole-file sha256 in the lock, and
each downloaded file must match it. Lock files resolved from unverified indexes
are rejected. Redirects are refused unless they stay on the registry host and
prefix, or go to one of redirect_hosts; credentials are never sent to a
redirect host.

Packages land at <cache>/<QueryEscape(scheme://host/repo)>/<arch>/<file>.apk
and indexes at <cache>/<QueryEscape(scheme://host/repo)>/<arch>/APKINDEX/<sha256>.tar.gz,
the layout apko and melange read with --offline --cache-dir.

The registry token, when needed, is read from the APK_REGISTRY_TOKEN
environment variable and sent as HTTP basic auth with the user "user".
"""

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
REDIRECT_HOST_RE = re.compile(r"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
PREFIX_RE = re.compile(r"^/([A-Za-z0-9._~-]+/)*$")
REPO_PATH_RE = re.compile(r"^(/[A-Za-z0-9._~-]+)*$")
ARCH_RE = re.compile(r"^[A-Za-z0-9_]+$")
APK_FILE_RE = re.compile(r"^[A-Za-z0-9._+~-]+\.apk$")
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
LOCKFILE_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
MAX_BYTES = 4 * 1024 * 1024 * 1024
CHUNK = 1024 * 1024


class FetchError(Exception):
    pass


class RetryableError(FetchError):
    pass


class PolicyError(Exception):
    pass


def go_query_escape(value):
    return urllib.parse.quote(value, safe="-_.~")


def split_url(url):
    """Return (scheme, host, repo_path, arch, filename) for an allowed-shape URL."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https":
        raise PolicyError(f"{url}: scheme must be https")
    if parsed.username is not None or parsed.password is not None:
        raise PolicyError(f"{url}: credentials in the URL are not allowed")
    if parsed.port is not None:
        raise PolicyError(f"{url}: an explicit port is not allowed")
    if parsed.query or parsed.fragment:
        raise PolicyError(f"{url}: query and fragment are not allowed")
    path = urllib.parse.unquote(parsed.path)
    segments = path.split("/")
    if len(segments) < 4 or segments[0] != "":
        raise PolicyError(f"{url}: path must be /<repository>/<arch>/<file>")
    if any(seg in ("", ".", "..") or "\x00" in seg for seg in segments[1:]):
        raise PolicyError(f"{url}: path has an empty, '.' or '..' segment")
    filename = segments[-1]
    arch = segments[-2]
    repo_path = "/".join(segments[:-2])
    if not ARCH_RE.match(arch):
        raise PolicyError(f"{url}: architecture segment {arch!r} is not allowed")
    if not REPO_PATH_RE.match(repo_path):
        raise PolicyError(f"{url}: repository path {repo_path!r} has characters outside [A-Za-z0-9._~-]")
    return parsed.scheme, parsed.hostname or "", repo_path, arch, filename


def check_allowed(url, host, prefix):
    scheme, url_host, repo_path, arch, filename = split_url(url)
    if url_host != host or urllib.parse.urlsplit(url).netloc != host:
        raise PolicyError(f"{url}: host is not the allowed registry host {host}")
    if not (repo_path + "/").startswith(prefix):
        raise PolicyError(f"{url}: path is not under the allowed prefix {prefix}")
    return scheme, url_host, repo_path, arch, filename


def cache_dir_for(cache, scheme, host, repo_path, arch):
    repo_dir = go_query_escape(f"{scheme}://{host}{repo_path}")
    return os.path.join(cache, repo_dir, arch)


def redirect_allowed(target_host, redirect_hosts):
    for allowed in redirect_hosts:
        if allowed.startswith("*."):
            if target_host.endswith(allowed[1:]) and target_host != allowed[2:]:
                return True
        elif target_host == allowed:
            return True
    return False


def load_request(path):
    with open(path, encoding="utf-8") as handle:
        request = json.load(handle)
    if not isinstance(request, dict):
        raise PolicyError("request must be a JSON object")
    host = request.get("host", "")
    prefix = request.get("path_prefix", "")
    redirect_hosts = request.get("redirect_hosts") or []
    lockfiles = request.get("lockfiles") or []
    archs = request.get("archs") or []
    if not isinstance(host, str) or not HOST_RE.match(host):
        raise PolicyError(f"host {host!r} is not a lowercase DNS name")
    if not isinstance(prefix, str) or not PREFIX_RE.match(prefix):
        raise PolicyError(f"path_prefix {prefix!r} must start and end with /")
    if not isinstance(redirect_hosts, list) or not all(isinstance(h, str) and REDIRECT_HOST_RE.match(h) for h in redirect_hosts):
        raise PolicyError("redirect_hosts must be a list of lowercase DNS names, optionally starting with *.")
    if not isinstance(lockfiles, list) or not lockfiles or not all(isinstance(p, str) for p in lockfiles):
        raise PolicyError("lockfiles must be a non-empty list of paths")
    if not isinstance(archs, list) or not all(isinstance(a, str) and ARCH_RE.match(a) for a in archs):
        raise PolicyError("archs must be a list of APK architecture names")
    return {
        "host": host,
        "path_prefix": prefix,
        "redirect_hosts": redirect_hosts,
        "lockfiles": lockfiles,
        "archs": archs,
    }


def resolve_lockfile(workspace, rel):
    if not LOCKFILE_RE.match(rel) or rel.startswith("/") or ".." in rel.split("/"):
        raise PolicyError(f"lock file path {rel!r} must be relative, without '..', using [A-Za-z0-9._/-]")
    root = os.path.realpath(workspace)
    full = os.path.realpath(os.path.join(root, rel))
    if not full.startswith(root + os.sep):
        raise PolicyError(f"lock file {rel} resolves outside the workspace")
    if not os.path.isfile(full):
        raise PolicyError(f"lock file {rel} not found")
    return full


def collect(request, workspace, cache):
    """Return (packages, indexes, errors). packages maps url to (sha256, dest)."""
    host = request["host"]
    prefix = request["path_prefix"]
    archs = set(request["archs"])
    packages = {}
    indexes = {}
    errors = []
    for rel in request["lockfiles"]:
        try:
            full = resolve_lockfile(workspace, rel)
            with open(full, encoding="utf-8") as handle:
                lock = json.load(handle)
        except (PolicyError, OSError, ValueError) as exc:
            errors.append(f"{rel}: {exc}")
            continue
        if not isinstance(lock, dict) or not isinstance(lock.get("contents"), dict):
            errors.append(f"{rel}: not an apko lock file (no contents)")
            continue
        if lock.get("unverified_indexes"):
            errors.append(f"{rel}: resolved from unverified repository indexes; regenerate it with signature verification")
        contents = lock["contents"]
        for pkg in contents.get("packages") or []:
            name = pkg.get("name", "?")
            arch = pkg.get("architecture", "")
            if archs and arch not in archs:
                continue
            if pkg.get("local"):
                if pkg.get("url"):
                    errors.append(f"{rel}: local package {name} has a url")
                continue
            url = pkg.get("url") or ""
            try:
                scheme, url_host, repo_path, url_arch, filename = check_allowed(url, host, prefix)
            except PolicyError as exc:
                errors.append(f"{rel}: package {name}: {exc}")
                continue
            if not APK_FILE_RE.match(filename):
                errors.append(f"{rel}: package {name}: {url}: file name is not <name>.apk")
                continue
            digest = pkg.get("sha256") or ""
            if not SHA256_RE.match(digest):
                errors.append(f"{rel}: package {name}: missing or malformed sha256; regenerate the lock file with an apko that records whole-file sha256")
                continue
            dest = os.path.join(cache_dir_for(cache, scheme, url_host, repo_path, url_arch), filename)
            previous = packages.get(url)
            if previous is not None and previous[0] != digest:
                errors.append(f"{rel}: package {name}: {url} is pinned to {digest} here and {previous[0]} in another lock file")
                continue
            packages[url] = (digest, dest)
        for key in ("repositories", "build_repositories"):
            for repo in contents.get(key) or []:
                url = repo.get("url") or ""
                arch = repo.get("architecture", "")
                scheme = urllib.parse.urlsplit(url).scheme
                if scheme == "":
                    continue
                if archs and arch not in archs:
                    continue
                try:
                    scheme, url_host, repo_path, url_arch, filename = check_allowed(url, host, prefix)
                except PolicyError as exc:
                    errors.append(f"{rel}: {key} {repo.get('name', '?')}: {exc}")
                    continue
                if filename != "APKINDEX.tar.gz":
                    errors.append(f"{rel}: {key} {repo.get('name', '?')}: {url} is not an APKINDEX.tar.gz")
                    continue
                indexes[url] = os.path.join(cache_dir_for(cache, scheme, url_host, repo_path, url_arch), "APKINDEX")
    return packages, indexes, errors


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Fetcher:
    def __init__(self, host, prefix, redirect_hosts, token, attempts=4, delay=2.0):
        self.host = host
        self.prefix = prefix
        self.redirect_hosts = redirect_hosts
        self.token = token
        self.attempts = attempts
        self.delay = delay
        self.opener = urllib.request.build_opener(NoRedirect)

    def open(self, url, headers):
        """Return (status, location, response). Subclassed in tests."""
        request = urllib.request.Request(url, headers=headers)
        try:
            response = self.opener.open(request, timeout=120)
            return response.status, None, response
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 303, 307, 308):
                location = exc.headers.get("Location")
                exc.close()
                return exc.code, location, None
            exc.close()
            return exc.code, None, None

    def _headers(self):
        headers = {"User-Agent": "fetch-apks"}
        if self.token:
            raw = f"user:{self.token}".encode()
            headers["Authorization"] = "Basic " + base64.b64encode(raw).decode()
        return headers

    def _resolve_redirect(self, url, location):
        if not location:
            raise FetchError(f"{url}: redirect without a Location header")
        target = urllib.parse.urljoin(url, location)
        parsed = urllib.parse.urlsplit(target)
        if parsed.scheme != "https":
            raise FetchError(f"{url}: refusing redirect to non-https {parsed.scheme}://{parsed.hostname}")
        if parsed.username is not None or parsed.password is not None:
            raise FetchError(f"{url}: refusing redirect with credentials in the URL")
        if parsed.netloc == self.host:
            try:
                check_allowed(urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", "")), self.host, self.prefix)
            except PolicyError as exc:
                raise FetchError(f"{url}: refusing redirect within the registry host: {exc}") from exc
            if parsed.query or parsed.fragment:
                raise FetchError(f"{url}: refusing redirect within the registry host with a query")
            return target, True
        if parsed.port is not None or not redirect_allowed(parsed.hostname or "", self.redirect_hosts):
            raise FetchError(f"{url}: refusing redirect to {parsed.hostname}, which is not in redirect_hosts")
        return target, False

    def _get_once(self, url, sink):
        status, location, response = self.open(url, self._headers())
        if status in (301, 302, 303, 307, 308):
            target, same_host = self._resolve_redirect(url, location)
            headers = self._headers() if same_host else {"User-Agent": "fetch-apks"}
            status, location, response = self.open(target, headers)
            if status in (301, 302, 303, 307, 308):
                raise FetchError(f"{url}: refusing a second redirect")
        if status != 200 or response is None:
            if status >= 500 or status == 429:
                raise RetryableError(f"{url}: HTTP {status}")
            raise FetchError(f"{url}: HTTP {status}")
        total = 0
        try:
            while True:
                chunk = response.read(CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    raise FetchError(f"{url}: larger than {MAX_BYTES} bytes")
                sink(chunk)
        finally:
            response.close()

    def get(self, url, dest_dir):
        """Download url into a temporary file in dest_dir. Return (path, sha256 hex)."""
        last = None
        for attempt in range(1, self.attempts + 1):
            handle = tempfile.NamedTemporaryFile(dir=dest_dir, prefix=".fetch-", delete=False)
            digest = hashlib.sha256()

            def sink(chunk, handle=handle, digest=digest):
                handle.write(chunk)
                digest.update(chunk)

            try:
                with handle:
                    self._get_once(url, sink)
                return handle.name, digest.hexdigest()
            except RetryableError as exc:
                last = exc
            except FetchError:
                os.unlink(handle.name)
                raise
            except (urllib.error.URLError, OSError, TimeoutError) as exc:
                last = FetchError(f"{url}: {exc}")
            os.unlink(handle.name)
            if attempt < self.attempts:
                time.sleep(self.delay * attempt)
        raise FetchError(f"{last} (after {self.attempts} attempts)")


def fetch_package(fetcher, url, digest, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp, actual = fetcher.get(url, os.path.dirname(dest))
    if "sha256:" + actual != digest:
        os.unlink(tmp)
        raise FetchError(f"{url}: sha256 mismatch: lock has {digest}, downloaded sha256:{actual}")
    os.replace(tmp, dest)
    return dest


def fetch_index(fetcher, url, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    tmp, actual = fetcher.get(url, dest_dir)
    with open(tmp, "rb") as handle:
        magic = handle.read(2)
    if magic != b"\x1f\x8b":
        os.unlink(tmp)
        raise FetchError(f"{url}: not a gzip file")
    dest = os.path.join(dest_dir, actual + ".tar.gz")
    os.replace(tmp, dest)
    return dest


def run(request, workspace, cache, fetcher, jobs=8):
    packages, indexes, errors = collect(request, workspace, cache)
    if errors:
        return errors, 0, 0
    os.makedirs(cache, exist_ok=True)
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {}
        for url, (digest, dest) in sorted(packages.items()):
            futures[pool.submit(fetch_package, fetcher, url, digest, dest)] = url
        for url, dest_dir in sorted(indexes.items()):
            futures[pool.submit(fetch_index, fetcher, url, dest_dir)] = url
        for future in concurrent.futures.as_completed(futures):
            try:
                future.result()
            except FetchError as exc:
                failures.append(str(exc))
    return sorted(failures), len(packages), len(indexes)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--request", required=True, help="request JSON file")
    parser.add_argument("--workspace", default=os.getcwd(), help="directory the lock file paths are relative to")
    parser.add_argument("--cache-dir", required=True, help="apko cache directory to populate")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args(argv)
    try:
        request = load_request(args.request)
    except (PolicyError, OSError, ValueError) as exc:
        print(f"::error::fetch-apks request: {exc}", file=sys.stderr)
        return 1
    token = os.environ.get("APK_REGISTRY_TOKEN", "")
    fetcher = Fetcher(request["host"], request["path_prefix"], request["redirect_hosts"], token)
    errors, n_packages, n_indexes = run(request, args.workspace, args.cache_dir, fetcher, args.jobs)
    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        print(f"fetch-apks: {len(errors)} error(s)", file=sys.stderr)
        return 1
    print(f"fetch-apks: {n_packages} package(s) verified by sha256 and {n_indexes} index(es) fetched into {args.cache_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
