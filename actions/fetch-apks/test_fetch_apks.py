import hashlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fetch_apks

HOST = "apk.example.dev"
PREFIX = "/org/"
BASE = f"https://{HOST}/org"
GOOD = b"apk-bytes"
GOOD_SHA = "sha256:" + hashlib.sha256(GOOD).hexdigest()
INDEX = b"\x1f\x8b index"


class FakeResponse(io.BytesIO):
    status = 200


class FakeFetcher(fetch_apks.Fetcher):
    def __init__(self, routes, redirect_hosts=None, token=""):
        super().__init__(HOST, PREFIX, redirect_hosts or [], token, attempts=2, delay=0)
        self.routes = routes
        self.calls = []

    def open(self, url, headers):
        self.calls.append((url, dict(headers)))
        route = self.routes.get(url)
        if route is None:
            return 404, None, None
        if isinstance(route, tuple):
            return route[0], route[1], None
        if isinstance(route, int):
            return route, None, None
        return 200, None, FakeResponse(route)


def pkg(name, url, sha=GOOD_SHA, arch="x86_64", **extra):
    entry = {"name": name, "version": "1-r0", "architecture": arch, "url": url}
    if sha is not None:
        entry["sha256"] = sha
    entry.update(extra)
    return entry


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workspace = os.path.join(self.tmp.name, "ws")
        self.cache = os.path.join(self.tmp.name, "cache")
        os.makedirs(self.workspace)

    def tearDown(self):
        self.tmp.cleanup()

    def write_lock(self, packages, repositories=None, rel="app.lock.json", **top):
        lock = {
            "version": "v1",
            "contents": {
                "keyring": [],
                "build_repositories": [],
                "runtime_repositories": [],
                "repositories": repositories or [],
                "packages": packages,
            },
        }
        lock.update(top)
        path = os.path.join(self.workspace, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(lock, handle)
        return rel

    def request(self, lockfiles, archs=None, redirect_hosts=None):
        return {
            "host": HOST,
            "path_prefix": PREFIX,
            "redirect_hosts": redirect_hosts or [],
            "lockfiles": lockfiles,
            "archs": archs or [],
        }

    def run_fetch(self, lockfiles, routes, **kwargs):
        fetcher = FakeFetcher(routes, kwargs.pop("redirect_hosts_fetcher", None), kwargs.pop("token", ""))
        errors, packages, indexes = fetch_apks.run(self.request(lockfiles, **kwargs), self.workspace, self.cache, fetcher, jobs=2)
        return errors, packages, indexes, fetcher

    def assert_error(self, errors, needle):
        self.assertTrue(any(needle in e for e in errors), f"no error containing {needle!r} in {errors}")


class LayoutTest(Case):
    def test_downloads_into_apko_cache_layout(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        index = f"{BASE}/x86_64/APKINDEX.tar.gz"
        rel = self.write_lock([pkg("foo", url)], [{"name": f"{HOST}/org/x86_64", "url": index, "architecture": "x86_64"}])
        errors, n_pkgs, n_idx, _ = self.run_fetch([rel], {url: GOOD, index: INDEX})
        self.assertEqual(errors, [])
        self.assertEqual((n_pkgs, n_idx), (1, 1))
        repo = os.path.join(self.cache, "https%3A%2F%2Fapk.example.dev%2Forg", "x86_64")
        with open(os.path.join(repo, "foo-1-r0.apk"), "rb") as handle:
            self.assertEqual(handle.read(), GOOD)
        index_files = os.listdir(os.path.join(repo, "APKINDEX"))
        self.assertEqual(index_files, [hashlib.sha256(INDEX).hexdigest() + ".tar.gz"])

    def test_go_query_escape(self):
        self.assertEqual(fetch_apks.go_query_escape("https://a.b/c_d-e.f~g"), "https%3A%2F%2Fa.b%2Fc_d-e.f~g")

    def test_local_packages_and_repositories_are_skipped(self):
        rel = self.write_lock(
            [{"name": "mine", "version": "1-r0", "architecture": "x86_64", "local": True}],
            [{"name": "/tmp/repo/x86_64", "url": "/tmp/repo/x86_64/APKINDEX.tar.gz", "architecture": "x86_64"}],
        )
        errors, n_pkgs, n_idx, fetcher = self.run_fetch([rel], {})
        self.assertEqual((errors, n_pkgs, n_idx), ([], 0, 0))
        self.assertEqual(fetcher.calls, [])

    def test_arch_filter(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        arm = f"{BASE}/aarch64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url), pkg("foo", arm, sha="sha256:" + "0" * 64, arch="aarch64")])
        errors, n_pkgs, _, fetcher = self.run_fetch([rel], {url: GOOD}, archs=["x86_64"])
        self.assertEqual((errors, n_pkgs), ([], 1))
        self.assertEqual([c[0] for c in fetcher.calls], [url])

    def test_token_sent_as_basic_auth(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, fetcher = self.run_fetch([rel], {url: GOOD}, token="secret")
        self.assertEqual(errors, [])
        self.assertTrue(fetcher.calls[0][1]["Authorization"].startswith("Basic "))


class PolicyTest(Case):
    def test_tampered_file_fails(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, _ = self.run_fetch([rel], {url: b"tampered"})
        self.assert_error(errors, "sha256 mismatch")
        self.assertFalse(os.path.exists(os.path.join(self.cache, "https%3A%2F%2Fapk.example.dev%2Forg", "x86_64", "foo-1-r0.apk")))

    def test_missing_sha256_fails(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url, sha=None)])
        errors, _, _, fetcher = self.run_fetch([rel], {url: GOOD})
        self.assert_error(errors, "missing or malformed sha256")
        self.assertEqual(fetcher.calls, [])

    def test_off_host_package_fails(self):
        url = "https://other.example.dev/org/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, fetcher = self.run_fetch([rel], {url: GOOD})
        self.assert_error(errors, "not the allowed registry host")
        self.assertEqual(fetcher.calls, [])

    def test_off_prefix_package_fails(self):
        url = f"https://{HOST}/elsewhere/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, _ = self.run_fetch([rel], {url: GOOD})
        self.assert_error(errors, "not under the allowed prefix")

    def test_prefix_is_segment_aligned(self):
        url = f"https://{HOST}/organisation/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, _ = self.run_fetch([rel], {url: GOOD})
        self.assert_error(errors, "not under the allowed prefix")

    def test_http_scheme_fails(self):
        url = f"http://{HOST}/org/x86_64/foo-1-r0.apk"
        rel = self.write_lock([pkg("foo", url)])
        errors, _, _, _ = self.run_fetch([rel], {url: GOOD})
        self.assert_error(errors, "scheme must be https")

    def test_port_userinfo_and_traversal_fail(self):
        for url, needle in [
            (f"https://{HOST}:8443/org/x86_64/foo-1-r0.apk", "port"),
            (f"https://u:p@{HOST}/org/x86_64/foo-1-r0.apk", "credentials"),
            (f"https://{HOST}/org/../x/x86_64/foo-1-r0.apk", "'..'"),
            (f"https://{HOST}/org/%2e%2e/x86_64/foo-1-r0.apk", "'..'"),
            (f"https://{HOST}/org/x86_64/foo-1-r0.apk?x=1", "query"),
        ]:
            rel = self.write_lock([pkg("foo", url)])
            errors, _, _, _ = self.run_fetch([rel], {})
            self.assert_error(errors, needle)

    def test_off_host_repository_fails(self):
        rel = self.write_lock([], [{"name": "x", "url": "https://other.example.dev/os/x86_64/APKINDEX.tar.gz", "architecture": "x86_64"}])
        errors, _, _, _ = self.run_fetch([rel], {})
        self.assert_error(errors, "not the allowed registry host")

    def test_unverified_indexes_fail(self):
        rel = self.write_lock([], unverified_indexes=True)
        errors, _, _, _ = self.run_fetch([rel], {})
        self.assert_error(errors, "unverified repository indexes")

    def test_conflicting_digests_fail(self):
        url = f"{BASE}/x86_64/foo-1-r0.apk"
        a = self.write_lock([pkg("foo", url)], rel="a.lock.json")
        b = self.write_lock([pkg("foo", url, sha="sha256:" + "1" * 64)], rel="b.lock.json")
        errors, _, _, _ = self.run_fetch([a, b], {url: GOOD})
        self.assert_error(errors, "pinned to")

    def test_lockfile_outside_workspace_fails(self):
        errors, _, _, _ = self.run_fetch(["../escape.lock.json"], {})
        self.assert_error(errors, "without '..'")

    def test_lockfile_symlink_outside_workspace_fails(self):
        outside = os.path.join(self.tmp.name, "outside.lock.json")
        with open(outside, "w", encoding="utf-8") as handle:
            json.dump({"contents": {}}, handle)
        os.symlink(outside, os.path.join(self.workspace, "link.lock.json"))
        errors, _, _, _ = self.run_fetch(["link.lock.json"], {})
        self.assert_error(errors, "outside the workspace")

    def test_all_policy_errors_reported_together(self):
        a = f"https://other.example.dev/org/x86_64/a-1-r0.apk"
        b = f"{BASE}/x86_64/b-1-r0.apk"
        rel = self.write_lock([pkg("a", a), pkg("b", b, sha=None)])
        errors, _, _, _ = self.run_fetch([rel], {})
        self.assertEqual(len(errors), 2, errors)


class RedirectTest(Case):
    def setUp(self):
        super().setUp()
        self.url = f"{BASE}/x86_64/foo-1-r0.apk"
        self.rel = self.write_lock([pkg("foo", self.url)])

    def test_redirect_off_host_refused_by_default(self):
        target = "https://storage.example.net/blob?sig=1"
        errors, _, _, _ = self.run_fetch([self.rel], {self.url: (303, target), target: GOOD})
        self.assert_error(errors, "not in redirect_hosts")

    def test_redirect_to_allowed_host_drops_credentials(self):
        target = "https://bucket.storage.example.net/blob?sig=1"
        errors, _, _, fetcher = self.run_fetch(
            [self.rel], {self.url: (303, target), target: GOOD},
            redirect_hosts_fetcher=["*.storage.example.net"], token="secret")
        self.assertEqual(errors, [])
        self.assertIn("Authorization", fetcher.calls[0][1])
        self.assertEqual(fetcher.calls[1][0], target)
        self.assertNotIn("Authorization", fetcher.calls[1][1])

    def test_wildcard_does_not_match_apex_or_lookalike(self):
        self.assertFalse(fetch_apks.redirect_allowed("storage.example.net", ["*.storage.example.net"]))
        self.assertFalse(fetch_apks.redirect_allowed("evilstorage.example.net", ["*.storage.example.net"]))
        self.assertTrue(fetch_apks.redirect_allowed("a.storage.example.net", ["*.storage.example.net"]))

    def test_redirect_to_http_refused(self):
        target = "http://storage.example.net/blob"
        errors, _, _, _ = self.run_fetch(
            [self.rel], {self.url: (302, target)}, redirect_hosts_fetcher=["storage.example.net"])
        self.assert_error(errors, "non-https")

    def test_second_redirect_refused(self):
        first = "https://storage.example.net/a"
        second = "https://storage.example.net/b"
        errors, _, _, _ = self.run_fetch(
            [self.rel], {self.url: (302, first), first: (302, second), second: GOOD},
            redirect_hosts_fetcher=["storage.example.net"])
        self.assert_error(errors, "second redirect")

    def test_redirect_within_host_outside_prefix_refused(self):
        target = f"https://{HOST}/other/x86_64/foo-1-r0.apk"
        errors, _, _, _ = self.run_fetch([self.rel], {self.url: (302, target), target: GOOD})
        self.assert_error(errors, "not under the allowed prefix")

    def test_redirected_content_still_verified(self):
        target = "https://storage.example.net/blob"
        errors, _, _, _ = self.run_fetch(
            [self.rel], {self.url: (303, target), target: b"tampered"},
            redirect_hosts_fetcher=["storage.example.net"])
        self.assert_error(errors, "sha256 mismatch")


class RequestTest(unittest.TestCase):
    def load(self, request):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(request, handle)
        try:
            return fetch_apks.load_request(handle.name)
        finally:
            os.unlink(handle.name)

    def test_rejects_bad_host_and_prefix(self):
        for request in [
            {"host": "APK.example.dev", "path_prefix": "/org/", "lockfiles": ["a"]},
            {"host": "apk.example.dev/org", "path_prefix": "/org/", "lockfiles": ["a"]},
            {"host": "apk.example.dev", "path_prefix": "/org", "lockfiles": ["a"]},
            {"host": "apk.example.dev", "path_prefix": "/org/", "lockfiles": []},
            {"host": "apk.example.dev", "path_prefix": "/org/", "lockfiles": ["a"], "redirect_hosts": ["*"]},
        ]:
            with self.assertRaises(fetch_apks.PolicyError, msg=str(request)):
                self.load(request)


if __name__ == "__main__":
    unittest.main()
