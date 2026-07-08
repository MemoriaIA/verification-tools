#!/usr/bin/env python3
"""
verify-release-manifest.py - verify a signed MemoriaIA verification-tools
release-candidate manifest.

This verifier is intentionally narrow. It verifies a detached RSA/SHA-256
signature over the exact manifest bytes, validates the manifest schema, checks
repo-bound file hashes from Git blobs, checks snapshot bytes from disk, and
recomputes the declared anchor commitment. It does not publish an external
anchor, prove historical completeness, or make any release-readiness claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_BOUNDARY = {
    "internal_snapshot_consistency_only": True,
    "no_historical_completeness_claim": True,
    "no_self_consistent_rewrite_protection_without_external_anchor": True,
    "no_public_release_claim": True,
}


def fail(message: str, code: int = 1) -> None:
    print(f"MANIFEST FAIL: {message}", file=sys.stderr)
    raise SystemExit(code)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_hex64(label: str, value: Any) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        fail(f"{label} must be lowercase 64-hex")
    return value


def run(cmd: list[str], cwd: Path | None = None, input_bytes: bytes | None = None) -> bytes:
    try:
        completed = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        fail(f"required command not found: {cmd[0]}", 2)
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        fail(f"command failed ({' '.join(cmd)}): {stderr}", 1)
    return completed.stdout


def git_blob_sha256(repo_root: Path, ref: str, rel_path: str) -> str:
    if rel_path.startswith("/") or "\\" in rel_path or ".." in Path(rel_path).parts:
        fail(f"unsafe tracked path: {rel_path}")
    blob = run(["git", "cat-file", "blob", f"{ref}:{rel_path}"], cwd=repo_root)
    return sha256_bytes(blob)


def verify_signature(manifest_path: Path, signature_path: Path, public_key_path: Path) -> None:
    if not signature_path.is_file():
        fail(f"signature file not found: {signature_path}", 2)
    if not public_key_path.is_file():
        fail(f"public key file not found: {public_key_path}", 2)
    key_text = public_key_path.read_text(encoding="utf-8", errors="strict")
    if "PRIVATE KEY" in key_text:
        fail("public key file contains private key material")
    run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-verify",
            str(public_key_path),
            "-signature",
            str(signature_path),
            str(manifest_path),
        ]
    )


def expected_anchor_preimage(manifest: dict[str, Any]) -> bytes:
    snapshot = manifest["snapshot"]
    tracked = manifest["tracked_files"]
    values = {
        "schema_sha256": tracked["memoriaia/schema/vault-schema.sql"]["sha256"],
        "verifier_sha256": tracked["memoriaia/verify/verify-hashchain.py"]["sha256"],
        "disclaimer_sha256": tracked["DISCLAIMER.md"]["sha256"],
    }
    text = (
        "vtools-anchor-v1\n"
        f"repo={manifest['repo']}\n"
        f"profile={manifest['profile']}\n"
        f"repo_commit={manifest['repo_commit']}\n"
        f"snapshot_sha256={snapshot['sha256']}\n"
        f"schema_sha256={values['schema_sha256']}\n"
        f"verifier_sha256={values['verifier_sha256']}\n"
        f"disclaimer_sha256={values['disclaimer_sha256']}\n"
    )
    return text.encode("utf-8")


def validate_manifest(manifest: dict[str, Any], repo_root: Path, release_mode: bool) -> None:
    if manifest.get("manifest_version") != "v1":
        fail("manifest_version must be v1")
    if manifest.get("manifest_type") != "memoriaia-verification-tools-release-candidate":
        fail("manifest_type is not recognized")
    if manifest.get("repo") != "MemoriaIA/verification-tools":
        fail("repo must be MemoriaIA/verification-tools")

    profile = manifest.get("profile")
    repo_commit = manifest.get("repo_commit")
    if release_mode:
        if profile != "release-candidate":
            fail("release mode requires profile=release-candidate")
        if not isinstance(repo_commit, str) or not HEX40.fullmatch(repo_commit):
            fail("release mode requires repo_commit to be a concrete 40-hex commit")
    else:
        if profile not in {"test-only-fixture", "release-candidate"}:
            fail("profile must be test-only-fixture or release-candidate")
        if repo_commit == "HEAD":
            repo_commit = "HEAD"
        elif not isinstance(repo_commit, str) or not HEX40.fullmatch(repo_commit):
            fail("repo_commit must be HEAD or a concrete 40-hex commit")

    boundary = manifest.get("claim_boundary")
    if not isinstance(boundary, dict):
        fail("claim_boundary must be an object")
    for key, expected in REQUIRED_BOUNDARY.items():
        if boundary.get(key) is not expected:
            fail(f"claim_boundary.{key} must be {expected}")

    snapshot = manifest.get("snapshot")
    if not isinstance(snapshot, dict):
        fail("snapshot must be an object")
    snapshot_path = snapshot.get("path")
    snapshot_sha = require_hex64("snapshot.sha256", snapshot.get("sha256"))
    if not isinstance(snapshot_path, str):
        fail("snapshot.path must be a string")
    snapshot_full = repo_root / snapshot_path
    if not snapshot_full.is_file():
        fail(f"snapshot file not found: {snapshot_path}", 2)
    actual_snapshot_sha = sha256_bytes(snapshot_full.read_bytes())
    if actual_snapshot_sha != snapshot_sha:
        fail(f"snapshot hash mismatch for {snapshot_path}: {actual_snapshot_sha}")

    tracked = manifest.get("tracked_files")
    if not isinstance(tracked, dict) or not tracked:
        fail("tracked_files must be a non-empty object")
    for required in (
        "memoriaia/schema/vault-schema.sql",
        "memoriaia/verify/verify-hashchain.py",
        "DISCLAIMER.md",
    ):
        if required not in tracked:
            fail(f"tracked_files missing required path: {required}")

    ref = str(repo_commit)
    for rel_path, item in tracked.items():
        if not isinstance(item, dict):
            fail(f"tracked file entry must be an object: {rel_path}")
        if item.get("hash_mode") != "git_blob_sha256":
            fail(f"tracked file {rel_path} must use hash_mode=git_blob_sha256")
        expected_sha = require_hex64(f"tracked_files.{rel_path}.sha256", item.get("sha256"))
        actual_sha = git_blob_sha256(repo_root, ref, rel_path)
        if actual_sha != expected_sha:
            fail(f"tracked blob hash mismatch for {rel_path}: {actual_sha}")

    anchor = manifest.get("anchor")
    if not isinstance(anchor, dict):
        fail("anchor must be an object")
    if anchor.get("type") != "head-commitment-v1":
        fail("anchor.type must be head-commitment-v1")
    anchor_status = anchor.get("external_publication")
    if release_mode and anchor_status in {None, "not_published_test_fixture", "not_published"}:
        fail("release mode requires an externally published anchor reference")
    commitment = require_hex64("anchor.commitment_sha256", anchor.get("commitment_sha256"))
    actual_commitment = sha256_bytes(expected_anchor_preimage(manifest))
    if actual_commitment != commitment:
        fail(f"anchor commitment mismatch: {actual_commitment}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify a signed verification-tools release-candidate manifest."
    )
    parser.add_argument("--manifest", required=True, help="Path to manifest JSON")
    parser.add_argument("--signature", required=True, help="Path to detached signature")
    parser.add_argument("--public-key", required=True, help="Path to public key")
    parser.add_argument("--repo-root", default=".", help="Repository root for tracked-file checks")
    parser.add_argument(
        "--release-mode",
        action="store_true",
        help="Require a concrete release-candidate profile and external anchor reference.",
    )
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    repo_root = Path(args.repo_root).resolve()
    if not manifest_path.is_file():
        fail(f"manifest file not found: {manifest_path}", 2)
    try:
        raw = manifest_path.read_bytes()
        manifest = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"manifest is not valid UTF-8 JSON: {exc}", 2)
    if not isinstance(manifest, dict):
        fail("manifest root must be an object")

    verify_signature(manifest_path, Path(args.signature), Path(args.public_key))
    validate_manifest(manifest, repo_root, args.release_mode)
    print("Release manifest VALID")
    print(f"Manifest SHA-256: {sha256_bytes(raw)}")
    print("Boundary: internal snapshot consistency only; no public or assurance-grade release claim.")


if __name__ == "__main__":
    main()
