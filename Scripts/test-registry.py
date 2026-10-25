#!/usr/bin/env python3
"""A small Swift package registry (SE-0292) for differential tests.

Serves packages from a directory laid out as

    <root>/<scope>/<name>/<version>/Package.swift (+ sources, Package@swift-*.swift)

and implements the read side of the registry API:

    GET /<scope>/<name>                          releases
    GET /<scope>/<name>/<version>                release metadata (source archive checksum)
    GET /<scope>/<name>/<version>/Package.swift  manifest (?swift-version=X for alternates)
    GET /<scope>/<name>/<version>.zip            source archive (deterministic zip)
    GET /identifiers?url=<url>                   identities for a source-control URL
    GET /availability                            200

A prebuilt `<root>/<scope>/<name>/<version>.zip` (e.g. from `swift package-registry publish
--dry-run`) is served as-is, and a `<version>.sig` next to it is announced as the archive's
CMS signature; the version directory then holds the archive's (signed) sources.

An optional `<root>/<scope>/<name>/<version>.metadata.json` replaces the default release
`metadata` object (author, licenseURL, repositoryURLs, …).

Archives are built in memory with fixed timestamps under a top-level `<scope>.<name>`
directory, so checksums are stable across runs.

Options:
    --port N            listen port (0 picks one; the chosen port is printed)
    --root DIR          package directory
    --scm-map FILE      JSON {"<url>": "<scope>.<name>"} for /identifiers
    --basic USER:PASS   require HTTP basic auth
    --token TOKEN       require a bearer token
    --log FILE          append one line per request
"""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_VERSION = "1"
JSON_TYPE = "application/json"
SWIFT_TYPE = "text/x-swift"
ZIP_TYPE = "application/zip"
SOURCE_ARCHIVE = "source-archive"
FIXED_TIME = (2024, 1, 1, 0, 0, 0)
MANIFEST = "Package.swift"
VERSION_SPECIFIC = re.compile(r"^Package@swift-(\d+(?:\.\d+){0,2})\.swift$")
TOOLS_VERSION = re.compile(r"swift-tools-version\s*:\s*(\d+(?:\.\d+){0,2})")


def normalized(version):
    """`5.8` and `5.8.0` name the same tools version."""
    parts = [int(part) for part in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


class Registry:
    def __init__(self, root, scm_map, basic, token, log):
        self.root = os.path.abspath(root)
        self.scm_map = scm_map
        self.basic = basic
        self.token = token
        self.log = log
        self.archives = {}

    def package_dir(self, scope, name):
        """Case-insensitive lookup, as registry identities are."""
        for candidate_scope in os.listdir(self.root):
            if candidate_scope.lower() != scope.lower():
                continue
            scope_dir = os.path.join(self.root, candidate_scope)
            for candidate_name in os.listdir(scope_dir):
                if candidate_name.lower() == name.lower():
                    return os.path.join(scope_dir, candidate_name), candidate_scope, candidate_name
        return None, None, None

    def archive(self, scope, name, version):
        key = (scope.lower(), name.lower(), version)
        if key in self.archives:
            return self.archives[key]
        package_dir, real_scope, real_name = self.package_dir(scope, name)
        prebuilt = os.path.join(package_dir, f"{version}.zip")
        if os.path.exists(prebuilt):
            with open(prebuilt, "rb") as handle:
                self.archives[key] = handle.read()
            return self.archives[key]
        source = os.path.join(package_dir, version)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for directory, subdirectories, files in os.walk(source):
                subdirectories.sort()
                for file in sorted(files):
                    path = os.path.join(directory, file)
                    relative = os.path.relpath(path, source)
                    info = zipfile.ZipInfo(f"{real_scope}.{real_name}/{relative}", FIXED_TIME)
                    info.external_attr = (os.stat(path).st_mode & 0o777) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    with open(path, "rb") as handle:
                        archive.writestr(info, handle.read())
        data = buffer.getvalue()
        self.archives[key] = data
        return data


def make_handler(registry):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            if registry.log:
                with open(registry.log, "a") as handle:
                    handle.write(f"{self.command} {self.path} {self.headers.get('Accept', '')} auth={self.headers.get('Authorization', '-')}\n")

        # MARK: Responses

        def send(self, status, body=b"", content_type=None, headers=None):
            self.send_response(status)
            self.send_header("Content-Version", API_VERSION)
            if content_type:
                self.send_header("Content-Type", content_type)
            for key, value in (headers or []):
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def send_json(self, status, value, headers=None):
            self.send(status, json.dumps(value, indent=2, sort_keys=True).encode(), JSON_TYPE, headers)

        def problem(self, status, detail):
            self.send(status, json.dumps({"detail": detail}).encode(), "application/problem+json")

        def authorized(self):
            header = self.headers.get("Authorization", "")
            if registry.basic:
                expected = "Basic " + base64.b64encode(registry.basic.encode()).decode()
                return header == expected
            if registry.token:
                return header == f"Bearer {registry.token}"
            return True

        # MARK: Routing

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            if not self.authorized():
                self.send(401, b"", headers=[("WWW-Authenticate", 'Basic realm="registry"')])
                return

            url = urlparse(self.path)
            parts = [part for part in url.path.split("/") if part]
            query = parse_qs(url.query)

            if parts == ["availability"]:
                return self.send(200)
            if parts == ["identifiers"]:
                return self.identifiers(query.get("url", [""])[0])
            if len(parts) == 2:
                return self.releases(*parts)
            if len(parts) == 3 and parts[2].endswith(".zip"):
                return self.source_archive(parts[0], parts[1], parts[2][: -len(".zip")])
            if len(parts) == 3:
                return self.release(*parts)
            if len(parts) == 4 and parts[3] == MANIFEST:
                return self.manifest(parts[0], parts[1], parts[2], query.get("swift-version", [None])[0])
            self.problem(404, "not found")

        # MARK: Endpoints

        def identifiers(self, url):
            identity = registry.scm_map.get(url)
            if not identity:
                return self.problem(404, "no identifiers")
            self.send_json(200, {"identifiers": [identity]})

        def releases(self, scope, name):
            package_dir, real_scope, real_name = registry.package_dir(scope, name)
            if not package_dir:
                return self.problem(404, "package not found")
            base = f"http://{self.headers['Host']}/{real_scope}/{real_name}"
            versions = sorted(entry for entry in os.listdir(package_dir) if os.path.isdir(os.path.join(package_dir, entry)))
            self.send_json(200, {"releases": {version: {"url": f"{base}/{version}"} for version in versions}})

        def release(self, scope, name, version):
            package_dir, real_scope, real_name = registry.package_dir(scope, name)
            if not package_dir or not os.path.isdir(os.path.join(package_dir, version)):
                return self.problem(404, "release not found")
            checksum = hashlib.sha256(registry.archive(scope, name, version)).hexdigest()
            metadata = {"description": f"{real_name} fixture"}
            sidecar = os.path.join(package_dir, f"{version}.metadata.json")
            if os.path.exists(sidecar):
                with open(sidecar) as handle:
                    metadata = json.load(handle)
            resource = {"name": SOURCE_ARCHIVE, "type": ZIP_TYPE, "checksum": checksum}
            signature = os.path.join(package_dir, f"{version}.sig")
            if os.path.exists(signature):
                with open(signature, "rb") as handle:
                    resource["signing"] = {"signatureBase64Encoded": base64.b64encode(handle.read()).decode(), "signatureFormat": "cms-1.0.0"}
            self.send_json(200, {
                "id": f"{real_scope}.{real_name}",
                "version": version,
                "resources": [resource],
                "metadata": metadata,
                "publishedAt": "2024-01-01T00:00:00Z",
            })

        def manifest(self, scope, name, version, swift_version):
            package_dir, real_scope, real_name = registry.package_dir(scope, name)
            release_dir = os.path.join(package_dir or "", version)
            if not package_dir or not os.path.isdir(release_dir):
                return self.problem(404, "release not found")

            # Alternates are advertised with Link headers, as the spec describes.
            files = sorted(os.listdir(release_dir))
            alternates = [(VERSION_SPECIFIC.match(file), file) for file in files]
            alternates = [(match.group(1), file) for match, file in alternates if match]

            filename = MANIFEST
            if swift_version:
                matching = [file for tools_version, file in alternates if normalized(tools_version) == normalized(swift_version)]
                if not matching:
                    return self.send(303, headers=[("Location", f"/{real_scope}/{real_name}/{version}/{MANIFEST}")])
                filename = matching[0]
            with open(os.path.join(release_dir, filename), "rb") as handle:
                body = handle.read()

            links = []
            base = f"http://{self.headers['Host']}/{real_scope}/{real_name}/{version}/{MANIFEST}"
            for tools_version, file in alternates:
                with open(os.path.join(release_dir, file)) as handle:
                    declared = TOOLS_VERSION.search(handle.read())
                links.append(
                    f'<{base}?swift-version={tools_version}>; rel="alternate"; '
                    f'filename="{file}"; swift-tools-version="{declared.group(1) if declared else tools_version}"'
                )
            headers = [("Content-Disposition", f'attachment; filename="{filename}"')]
            if links:
                headers.append(("Link", ", ".join(links)))
            self.send(200, body, SWIFT_TYPE, headers)

        def source_archive(self, scope, name, version):
            package_dir, real_scope, real_name = registry.package_dir(scope, name)
            if not package_dir or not os.path.isdir(os.path.join(package_dir, version)):
                return self.problem(404, "release not found")
            data = registry.archive(scope, name, version)
            digest = base64.b64encode(hashlib.sha256(data).digest()).decode()
            self.send(200, data, ZIP_TYPE, [
                ("Content-Disposition", f'attachment; filename="{real_name}-{version}.zip"'),
                ("Digest", f"sha-256={digest}"),
            ])

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--root", required=True)
    parser.add_argument("--scm-map")
    parser.add_argument("--basic")
    parser.add_argument("--token")
    parser.add_argument("--log")
    arguments = parser.parse_args()

    scm_map = {}
    if arguments.scm_map:
        with open(arguments.scm_map) as handle:
            scm_map = json.load(handle)

    registry = Registry(arguments.root, scm_map, arguments.basic, arguments.token, arguments.log)
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), make_handler(registry))
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
