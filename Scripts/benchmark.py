#!/usr/bin/env python3
"""Benchmarks swx against SwiftPM on one package, as the README's tables report.

Scenarios (each tool gets its own fresh caches for "cold"):
    cold          empty caches, no Package.resolved, no .build
    warm          warm caches, no Package.resolved
    fresh-clone   warm caches, Package.resolved present, no .build
    no-op         everything already resolved

Usage:
    python3 -I Scripts/benchmark.py <package-dir> [--swx PATH] [--runs N] [--json FILE]

Prints a Markdown table of medians; --json also writes the raw timings.
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

SCENARIOS = ["cold", "warm", "fresh-clone", "no-op"]


def run(command, cwd, env):
    start = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    elapsed = time.monotonic() - start
    if result.returncode != 0:
        sys.exit(f"{' '.join(command)} failed in {cwd}:\n{result.stderr.decode()[-2000:]}")
    return elapsed


def copy_package(source, destination):
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns(".build", "Package.resolved", ".swiftpm"))


class Tool:
    def __init__(self, name, work, swx):
        self.name = name
        self.work = work
        self.swx = swx
        self.cache = os.path.join(work, f"{name}-cache")

    def command(self):
        # SwiftPM keeps its shared caches under --cache-path; swx keeps its store there.
        if self.name == "swiftpm":
            return ["swift", "package", "resolve", "--cache-path", self.cache]
        return [self.swx, "package", "resolve", "--cache-path", self.cache]

    def measure(self, package, scenario, run_index):
        directory = os.path.join(self.work, f"{self.name}-{scenario}-{run_index}")
        copy_package(package, directory)
        env = dict(os.environ)

        if scenario == "cold":
            shutil.rmtree(self.cache, ignore_errors=True)
            return run(self.command(), directory, env)

        # Every other scenario starts from warm caches.
        run(self.command(), directory, env)
        if scenario == "warm":
            os.remove(os.path.join(directory, "Package.resolved"))
            shutil.rmtree(os.path.join(directory, ".build"), ignore_errors=True)
        elif scenario == "fresh-clone":
            shutil.rmtree(os.path.join(directory, ".build"), ignore_errors=True)
        return run(self.command(), directory, env)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("package")
    parser.add_argument("--swx", default=None)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--json")
    arguments = parser.parse_args()

    package = os.path.abspath(arguments.package)
    swx = os.path.abspath(arguments.swx) if arguments.swx else shutil.which("swx")
    if not swx:
        sys.exit("swx not found; pass --swx")

    work = tempfile.mkdtemp(prefix="swx-benchmark-")
    try:
        results = {}
        for name in ["swiftpm", "swx"]:
            tool = Tool(name, work, swx)
            for scenario in SCENARIOS:
                timings = [tool.measure(package, scenario, index) for index in range(arguments.runs)]
                results.setdefault(scenario, {})[name] = timings
                print(f"{name:8} {scenario:12} {statistics.median(timings):7.2f}s  ({', '.join(f'{t:.2f}' for t in timings)})", file=sys.stderr)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"| Scenario ({os.path.basename(package)}) | SwiftPM | swx | Speedup |")
    print("|---|---|---|---|")
    for scenario in SCENARIOS:
        swiftpm = statistics.median(results[scenario]["swiftpm"])
        ours = statistics.median(results[scenario]["swx"])
        ratio = swiftpm / ours
        speedup = f"{ratio:.0f}x" if ratio >= 10 else f"{ratio:.1f}x"
        print(f"| {scenario} | {swiftpm:.2f} s | {ours:.2f} s | {speedup} |")

    if arguments.json:
        with open(arguments.json, "w") as handle:
            json.dump({"package": os.path.basename(package), "runs": arguments.runs, "timings": results}, handle, indent=2)


if __name__ == "__main__":
    main()
