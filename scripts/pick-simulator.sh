#!/usr/bin/env bash
# Печатает UDID доступного симулятора iPhone с самой новой iOS (предпочтительно модель без Pro/Max/Plus).
set -euo pipefail

xcrun simctl list devices available --json | python3 -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, items in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in items:
        name = device["name"]
        if not name.startswith("iPhone"):
            continue
        plain = not re.search(r"Pro|Max|Plus|mini|SE|Air|e$", name)
        candidates.append((version, plain, name, device["udid"]))

if not candidates:
    sys.exit("No available iPhone simulator")

version, _, name, udid = max(candidates)
print(f"{name} iOS {version[0]}.{version[1]}", file=sys.stderr)
print(udid)
'
