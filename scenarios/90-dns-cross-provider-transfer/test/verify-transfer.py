#!/usr/bin/env python3
"""Cross-provider DNS transfer parity verifier.

Loads two `wfctl infra import-all --output ...` state files and the
lossiness charter, then asserts every (type, name, data, ttl) record
tuple in the source state has a matching tuple in the target state
modulo the per-(provider, record_type, field) exclusions declared in
lossiness.yaml. NS records are excluded from the matrix entirely.

Usage:
    verify-transfer.py <source-state.json> <target-state.json> <lossiness.yaml>

Exit codes:
    0 — every source record present in target (modulo exclusions)
    1 — at least one missing record (printed to stderr)
    2 — input file parse error
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
except ImportError:
    print("ERROR: PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


CANONICAL_FIELDS = ("type", "name", "data", "ttl", "priority")


def load_state(path: str) -> list[dict[str, Any]]:
    """Pull the records[] list out of every resource in an import-all output.

    wfctl infra import-all --output writes a JSON file whose top-level
    shape is either {"resources": [...]} or just [...] depending on
    version; we accept both. Each resource's records live at
    .applied_config.records (per ResourceState's json tag — see
    workflow/interfaces/iac_state.go:37).
    """
    data = json.loads(Path(path).read_text())
    if isinstance(data, dict):
        resources = data.get("resources") or [data]
    else:
        resources = data
    records: list[dict[str, Any]] = []
    for r in resources:
        applied = r.get("applied_config") or {}
        for rec in applied.get("records") or []:
            records.append(rec)
    return records


def normalize(rec: dict[str, Any], provider: str, exclude: list[dict[str, Any]]) -> tuple:
    """Build a comparison key for a record, masking excluded fields.

    The key is a sorted-tuple of (k, v) pairs across CANONICAL_FIELDS
    minus any field excluded for this (provider, record_type) pair.
    """
    rtype = str(rec.get("type", ""))
    excluded_fields: set[str] = set()
    for entry in exclude:
        if entry.get("provider") != provider:
            continue
        rt = entry.get("record_type", "*")
        if rt != "*" and rt != rtype:
            continue
        excluded_fields.add(str(entry.get("field", "")))
    items: list[tuple[str, Any]] = []
    for key in CANONICAL_FIELDS:
        if key in excluded_fields:
            continue
        if key not in rec:
            continue
        items.append((key, rec[key]))
    return tuple(sorted(items))


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    source_path, target_path, lossiness_path = argv[1], argv[2], argv[3]
    try:
        source = load_state(source_path)
        target = load_state(target_path)
        charter = yaml.safe_load(Path(lossiness_path).read_text())
    except (OSError, json.JSONDecodeError, yaml.YAMLError) as exc:
        print(f"ERROR: input parse: {exc}", file=sys.stderr)
        return 2
    matrix: list[str] = charter.get("matrix") or []
    exclude: list[dict[str, Any]] = charter.get("exclude") or []
    # For the stub-driven scenario, both sides report provider name
    # "stub-A" / "stub-B"; treat them as their underlying-cloud
    # equivalents for exclusion lookup so the charter is reusable
    # when the stub is swapped for a real provider.
    source_provider = "digitalocean"
    target_provider = "cloudflare"
    # Build sets of normalized keys per side, scoped to matrix types.
    src_keys = {
        normalize(r, source_provider, exclude)
        for r in source
        if str(r.get("type", "")) in matrix
    }
    tgt_keys = {
        normalize(r, target_provider, exclude)
        for r in target
        if str(r.get("type", "")) in matrix
    }
    missing = src_keys - tgt_keys
    if missing:
        print(f"FAIL: {len(missing)} record(s) in source missing from target after exclusions:", file=sys.stderr)
        for key in sorted(missing):
            print(f"  {dict(key)}", file=sys.stderr)
        return 1
    print(f"OK: {len(src_keys)} source records all present in target (modulo charter exclusions)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
