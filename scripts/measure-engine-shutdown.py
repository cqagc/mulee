#!/usr/bin/env python3
"""Measure the App's real engine stop adapters using disposable state directories."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request


DEBIAN_TORRENT = (
    "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/"
    "debian-13.7.0-amd64-netinst.iso.torrent"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Skip the public Debian swarm")
    parser.add_argument("--output", type=Path, help="Write JSON measurements")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    environment = dict(os.environ)
    for name, binary in (("MULEE_ARIA2C", "aria2c"), ("MULEE_AMULED", "amuled"),
                         ("MULEE_TORRENTD", "mulee-torrentd")):
        path = root / "build" / "thirdparty" / "bin" / binary
        if not path.is_file():
            parser.error(f"Missing engine binary: {binary}")
        environment[name] = str(path)
    environment["MULEE_MEASURE_SHUTDOWN"] = "1"
    measurements = []
    with tempfile.TemporaryDirectory(prefix="mulee-shutdown-") as directory:
        environment["MULEE_SHUTDOWN_ROOT"] = directory
        if not arguments.offline:
            torrent = Path(directory) / "debian.torrent"
            with urllib.request.urlopen(DEBIAN_TORRENT, timeout=45) as response:
                torrent.write_bytes(response.read(2 * 1024 * 1024))
            environment["MULEE_SHUTDOWN_TORRENT"] = str(torrent)
        command = ["swift", "test", "--package-path", str(root / "Packages" / "MuleeCore"),
                   "--filter", "EngineShutdownTests"]
        result = subprocess.run(command, cwd=root, env=environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, end="", flush=True)
        for line in result.stdout.splitlines():
            if line.startswith("SHUTDOWN_MEASUREMENT "):
                measurements.append(json.loads(line.removeprefix("SHUTDOWN_MEASUREMENT ")))
    if arguments.output:
        arguments.output.write_text(json.dumps(measurements, indent=2) + "\n", encoding="utf-8")
    if result.returncode:
        raise SystemExit(result.returncode)
    expected = 8 if arguments.offline else 9
    if len(measurements) != expected:
        raise SystemExit(f"Expected {expected} measurements, received {len(measurements)}")
    print("\nEngine                 State          Stop (s)  Saved bytes")
    for item in measurements:
        print(f"{item['engine']:<22} {item['state']:<14} {item['seconds']:>8.3f}  {item['bytes']}")


if __name__ == "__main__":
    main()
