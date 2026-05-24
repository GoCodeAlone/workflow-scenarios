#!/usr/bin/env python3
"""Validate sanitized DNS/IaC replay fixtures without provider accounts."""

from __future__ import annotations

import ipaddress
import json
import sys
from pathlib import Path

EXAMPLE_IPV4_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")
)
EXAMPLE_IPV6_NETWORKS = (ipaddress.ip_network("2001:db8::/32"),)


class Reporter:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def pass_(self, message: str) -> None:
        self.passed += 1
        print(f"PASS: {message}")

    def fail(self, message: str) -> None:
        self.failed += 1
        print(f"FAIL: {message}")

    def check(self, condition: bool, message: str) -> None:
        if condition:
            self.pass_(message)
        else:
            self.fail(message)


def canonical_name(name: str, domain: str) -> str:
    if name in ("", "@"):
        return domain.rstrip(".")
    name = name.rstrip(".")
    domain = domain.rstrip(".")
    if name == domain or name.endswith("." + domain):
        return name
    return f"{name}.{domain}"


def canonical_record(record: dict, domain: str) -> tuple:
    record_type = str(record.get("type", "")).upper()
    name = canonical_name(str(record.get("name", "")), domain)
    value = str(record.get("value", record.get("data", ""))).rstrip(".")
    ttl = int(record.get("ttl", 0))
    priority = record.get("priority", record.get("mx"))
    proxied = record.get("proxied")
    return record_type, name, value, ttl, priority, proxied


def is_example_address(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    networks = EXAMPLE_IPV6_NETWORKS if addr.version == 6 else EXAMPLE_IPV4_NETWORKS
    return any(addr in network for network in networks)


def load_fixture(path: Path, reporter: Reporter) -> dict | None:
    if not path.exists():
        reporter.fail(f"fixture exists: {path}")
        return None
    try:
        with path.open() as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        reporter.fail(f"fixture is valid JSON: {exc}")
        return None
    reporter.pass_("fixture is valid JSON")
    return data


def validate_export_envelope(data: dict, reporter: Reporter) -> None:
    reporter.check(data.get("schema") == "workflow.dns-portfolio.export.v1", "fixture declares export schema v1")
    metadata = data.get("metadata", {})
    reporter.check(metadata.get("sanitized") is True, "fixture is explicitly marked sanitized")
    reporter.check(bool(metadata.get("generated_at")), "fixture includes generation timestamp")
    reporter.check(bool(metadata.get("source_portfolio_id")), "fixture includes non-sensitive source portfolio id")

    sanitization = data.get("sanitization", {})
    reporter.check(sanitization.get("status") == "sanitized", "sanitization status is sanitized")
    rules = sanitization.get("rules", [])
    for rule in ("domain_aliases", "example_ip_addresses", "txt_secret_redaction", "email_redaction"):
        reporter.check(rule in rules, f"sanitization rule records {rule}")
    reporter.check(isinstance(sanitization.get("forbidden_patterns"), list), "sanitization declares forbidden patterns")


def validate_snapshot_shape(data: dict, reporter: Reporter) -> list[dict]:
    snapshots = data.get("snapshots", [])
    reporter.check(isinstance(snapshots, list) and len(snapshots) >= 4, "fixture declares at least four provider snapshots")
    for snapshot in snapshots:
        label = snapshot.get("id", "<missing-id>")
        reporter.check(bool(snapshot.get("provider")), f"{label} declares provider")
        reporter.check(bool(snapshot.get("domain")), f"{label} declares domain")
        reporter.check(bool(snapshot.get("authority")), f"{label} declares authority metadata")
        records = snapshot.get("records", [])
        reporter.check(isinstance(records, list) and bool(records), f"{label} declares records")
        for idx, record in enumerate(records):
            prefix = f"{label} record {idx}"
            reporter.check(bool(record.get("type")), f"{prefix} has type")
            reporter.check("name" in record, f"{prefix} has name")
            reporter.check(bool(record.get("value", record.get("data"))), f"{prefix} has value")
            reporter.check(isinstance(record.get("ttl"), int) and record.get("ttl") > 0, f"{prefix} has positive ttl")
    return snapshots


def validate_sanitized_addresses(snapshots: list[dict], reporter: Reporter) -> None:
    unsafe = []
    for snapshot in snapshots:
        for record in snapshot.get("records", []):
            if str(record.get("type", "")).upper() in {"A", "AAAA"}:
                value = str(record.get("value", record.get("data", "")))
                if not is_example_address(value):
                    unsafe.append((snapshot.get("id"), record.get("name"), value))
    reporter.check(not unsafe, "fixtures use only documentation/example IP addresses")


def validate_redaction(data: dict, snapshots: list[dict], reporter: Reporter) -> None:
    forbidden = [str(pattern).lower() for pattern in data.get("sanitization", {}).get("forbidden_patterns", [])]
    serialized = json.dumps({"snapshots": snapshots, "migration": data.get("migration", {})}, sort_keys=True).lower()
    for pattern in forbidden:
        reporter.check(pattern not in serialized, f"fixture excludes forbidden pattern {pattern}")

    txt_records = [
        str(record.get("value", record.get("data", "")))
        for snapshot in snapshots
        for record in snapshot.get("records", [])
        if str(record.get("type", "")).upper() == "TXT"
    ]
    secret_markers = ("google-site-verification=", "keybase-site-verification=")
    leaked = [value for value in txt_records if any(marker in value.lower() for marker in secret_markers)]
    leaked.extend(
        value for value in txt_records
        if "v=dkim1" in value.lower() and "<redacted>" not in value.lower()
    )
    reporter.check(not leaked, "TXT records redact verification tokens and DKIM public keys")


def validate_provider_coverage(snapshots: list[dict], reporter: Reporter) -> None:
    providers = {str(snapshot.get("provider", "")).lower() for snapshot in snapshots}
    for provider in ("cloudflare", "digitalocean", "namecheap", "hover", "aws", "azure", "gcp"):
        reporter.check(provider in providers, f"provider coverage includes {provider}")


def validate_provider_output_contracts(data: dict, reporter: Reporter) -> None:
    contracts = data.get("provider_output_contracts", {})
    reporter.check(isinstance(contracts, dict) and bool(contracts), "fixture declares provider output contracts")
    required = {
        "cloudflare": {"domain", "records", "record_count", "authority", "authority.name_servers", "authority.original_name_servers"},
        "digitalocean": {"domain", "records", "record_count", "zone_file", "authority", "authority.name_servers"},
        "namecheap": {"domain", "record_count", "authority", "authority.is_using_our_dns", "authority.email_type"},
        "hover": {"domain", "records", "record_count", "authority", "authority.name_servers"},
        "aws": {"domain", "records", "record_count", "authority", "authority.name_servers"},
        "azure": {"domain", "records", "record_count", "authority", "authority.name_servers"},
        "gcp": {"domain", "records", "record_count", "authority", "authority.name_servers"},
    }
    for provider, required_paths in required.items():
        contract = contracts.get(provider, {})
        reporter.check(isinstance(contract, dict), f"{provider} output contract is an object")
        resource_types = contract.get("resource_types", [])
        reporter.check("infra.dns" in resource_types, f"{provider} output contract covers infra.dns")
        paths = set(contract.get("dns_required_outputs", []))
        for path in sorted(required_paths):
            reporter.check(path in paths, f"{provider} output contract requires {path}")
    cloudflare = contracts.get("cloudflare", {})
    reporter.check(cloudflare.get("delete_unlisted_flag") == "manage_unlisted", "Cloudflare contract requires explicit manage_unlisted for destructive reconciliation")
    digitalocean = contracts.get("digitalocean", {})
    reporter.check(digitalocean.get("delete_unlisted_flag") == "unsupported", "DigitalOcean contract does not delete undeclared DNS records")
    namecheap = contracts.get("namecheap", {})
    reporter.check(namecheap.get("apply_semantics") == "whole_zone_replace", "Namecheap contract declares whole-zone replace semantics")
    hover = contracts.get("hover", {})
    reporter.check(hover.get("apply_semantics") == "read_only_import", "Hover contract remains read-only import")
    aws = contracts.get("aws", {})
    reporter.check(aws.get("apply_semantics") == "record_upsert_preserve_unlisted", "AWS Route53 contract declares record upsert semantics")
    azure = contracts.get("azure", {})
    reporter.check(azure.get("apply_semantics") == "record_upsert_preserve_unlisted", "Azure DNS contract declares record upsert semantics")
    gcp = contracts.get("gcp", {})
    reporter.check(gcp.get("apply_semantics") == "record_upsert_preserve_unlisted", "GCP Cloud DNS contract declares record upsert semantics")


def validate_import_state_contracts(data: dict, reporter: Reporter) -> None:
    contracts = data.get("import_state_contracts", {})
    reporter.check(isinstance(contracts, dict) and bool(contracts), "fixture declares import state contracts")
    reporter.check(contracts.get("applied_config_source") == "adoption", "imported state is marked as adoption provenance")

    dns_required = set(contracts.get("dns_required_applied_config", []))
    for path in ("provider", "domain", "records"):
        reporter.check(path in dns_required, f"DNS imported applied config requires {path}")

    forbidden = set(contracts.get("forbidden_applied_config_fields", []))
    for path in ("id", "provider_id", "record_id", "epp_code", "confirm_transfer"):
        reporter.check(path in forbidden, f"imported applied config forbids {path}")

    mappings = contracts.get("provider_record_mappings", {})
    namecheap = mappings.get("namecheap", {})
    reporter.check(namecheap.get("value_output") == "address", "Namecheap import maps address output to DNS record data")
    reporter.check(namecheap.get("mx_output") == "mx_pref", "Namecheap import maps mx_pref output to DNS record mx")
    cloudflare = mappings.get("cloudflare", {})
    reporter.check(cloudflare.get("provider_record_id_output") == "id", "Cloudflare import treats record id as provider-only output")
    reporter.check(cloudflare.get("provider_record_id_applied") == "forbidden", "Cloudflare import omits provider record id from applied config")


def validate_record_preservation(data: dict, snapshots: list[dict], reporter: Reporter) -> None:
    source = next((s for s in snapshots if s.get("id") == data.get("migration", {}).get("source_snapshot")), None)
    target = next((s for s in snapshots if s.get("id") == data.get("migration", {}).get("target_snapshot")), None)
    if source is None or target is None:
        reporter.fail("migration source and target snapshots resolve")
        return
    reporter.pass_("migration source and target snapshots resolve")

    source_records = {canonical_record(record, source["domain"]) for record in source.get("records", [])}
    target_records = {canonical_record(record, target["domain"]) for record in target.get("records", [])}

    source_by_type = {record[0] for record in source_records}
    for required_type in ("MX", "TXT", "CNAME", "A"):
        reporter.check(required_type in source_by_type, f"source includes {required_type} records")

    target_by_type = {record[0] for record in target_records}
    for required_type in ("MX", "TXT", "CNAME", "A"):
        reporter.check(required_type in target_by_type, f"target includes migrated {required_type} records")

    source_mx_values = {record[2:] for record in source_records if record[0] == "MX"}
    target_mx_values = {record[2:] for record in target_records if record[0] == "MX"}
    reporter.check(source_mx_values <= target_mx_values, "MX records are preserved in target")

    source_txt_values = {record[2] for record in source_records if record[0] == "TXT"}
    reporter.check(any("v=spf1" in value for value in source_txt_values), "source includes SPF TXT")
    reporter.check(any("v=DMARC1" in value for value in source_txt_values), "source includes DMARC TXT")


def validate_migration_safety(data: dict, snapshots: list[dict], reporter: Reporter) -> None:
    migration = data.get("migration", {})
    reporter.check(migration.get("delete_unlisted") is False, "destructive deletes require explicit opt-in")
    reporter.check(migration.get("apply_mode") == "plan_only", "migration defaults to plan-only apply mode")

    target = next((s for s in snapshots if s.get("id") == migration.get("target_snapshot")), {})
    nameservers = [str(ns).lower() for ns in target.get("authority", {}).get("name_servers", [])]
    reporter.check(any(ns.endswith(".ns.cloudflare.com") for ns in nameservers), "target exposes Cloudflare nameservers")

    required_steps = migration.get("required_manual_steps", [])
    reporter.check("switch_registrar_nameservers" in required_steps, "migration tracks registrar nameserver switch")
    reporter.check("verify_mx_delivery" in required_steps, "migration tracks MX delivery verification")


def main(argv: list[str]) -> int:
    reporter = Reporter()
    if len(argv) != 2:
        print("Usage: validate_dns_replay.py <dns-portfolio.json>")
        return 2

    data = load_fixture(Path(argv[1]), reporter)
    if data is not None:
        validate_export_envelope(data, reporter)
        snapshots = validate_snapshot_shape(data, reporter)
        validate_sanitized_addresses(snapshots, reporter)
        validate_redaction(data, snapshots, reporter)
        validate_provider_coverage(snapshots, reporter)
        validate_provider_output_contracts(data, reporter)
        validate_import_state_contracts(data, reporter)
        validate_record_preservation(data, snapshots, reporter)
        validate_migration_safety(data, snapshots, reporter)

    print("")
    print(f"Results: {reporter.passed} passed, {reporter.failed} failed")
    return 0 if reporter.failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
