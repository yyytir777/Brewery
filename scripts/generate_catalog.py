#!/usr/bin/env python3
import argparse
import datetime
import json
import os
import tempfile
import urllib.request

FORMULA_URL = "https://formulae.brew.sh/api/formula.json"
CASK_URL = "https://formulae.brew.sh/api/cask.json"

def normalize_formula(raw):
    name = raw["name"]
    return {"id": f"formula:{name}", "name": name, "kind": "formula", "description": raw.get("desc"), "homepage": raw.get("homepage"), "latestVersion": raw.get("versions", {}).get("stable")}

def normalize_cask(raw):
    name = raw["token"]
    return {"id": f"cask:{name}", "name": name, "kind": "cask", "description": raw.get("desc"), "homepage": raw.get("homepage"), "latestVersion": raw.get("version")}

def build_snapshot(formulae, casks, generated_at):
    packages = [normalize_formula(item) for item in formulae] + [normalize_cask(item) for item in casks]
    packages.sort(key=lambda item: (0 if item["kind"] == "formula" else 1, item["name"]))
    return {"schemaVersion": 1, "generatedAt": generated_at, "packages": packages}

def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Brewery catalog generator"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

def write_atomic(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".catalog-", suffix=".json")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(payload, output, ensure_ascii=False, separators=(",", ":"))
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="Brewery/Resources/catalog.json")
    args = parser.parse_args()
    generated_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    write_atomic(args.output, build_snapshot(fetch_json(FORMULA_URL), fetch_json(CASK_URL), generated_at))

if __name__ == "__main__":
    main()
