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
import os
import re
import subprocess
import sys
import tempfile
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
ANCHOR_URI = re.compile(r"^(https://|urn:)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+$")
RFC3339_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
PROOF_CRITICAL_GIT_ENV = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_EXEC_PATH",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_PAGER",
)


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
    env = os.environ.copy()
    for name in PROOF_CRITICAL_GIT_ENV:
        env.pop(name, None)
    # Fail closed against Git replacement refs for proof-critical checks.
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    try:
        completed = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            env=env,
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


def git_run(args: list[str], cwd: Path | None = None) -> bytes:
    """Run a proof-critical git command with replacement refs disabled."""
    return run(["git", "--no-replace-objects", *args], cwd=cwd)


def git_blob_sha256(repo_root: Path, ref: str, rel_path: str) -> str:
    if rel_path.startswith("/") or "\\" in rel_path or ".." in Path(rel_path).parts:
        fail(f"unsafe tracked path: {rel_path}")
    blob = git_run(["cat-file", "blob", f"{ref}:{rel_path}"], cwd=repo_root)
    return sha256_bytes(blob)


def require_repo_relative_path(label: str, value: Any) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty relative path")
    path = Path(value)
    if path.is_absolute() or "\\" in value or ".." in path.parts:
        fail(f"{label} must stay within the repository: {value}")
    return value


def verify_signature_bytes(
    manifest_bytes: bytes,
    signature_bytes: bytes,
    public_key_bytes: bytes,
    release_mode: bool,
    expected_public_key_sha256: str | None,
) -> None:
    """Verify signature over the exact bytes already read by the verifier.

    OpenSSL is only fed stable tempfiles written from those already-read bytes,
    never the original mutable caller paths after parse/hash checks.
    """
    try:
        key_text = public_key_bytes.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        fail(f"public key is not valid UTF-8: {exc}", 2)
    if "PRIVATE KEY" in key_text:
        fail("public key file contains private key material")
    if release_mode:
        expected = require_hex64(
            "expected_public_key_sha256",
            expected_public_key_sha256,
        )
        actual = sha256_bytes(public_key_bytes)
        if actual != expected:
            fail(f"public key hash mismatch: {actual}")

    # Stable private directory; bytes are the same ones already hashed/parsed.
    with tempfile.TemporaryDirectory(prefix="vtools-manifest-verify-") as tmp:
        tmp_path = Path(tmp)
        key_path = tmp_path / "public-key.pub"
        sig_path = tmp_path / "manifest.sig"
        man_path = tmp_path / "manifest.json"
        key_path.write_bytes(public_key_bytes)
        sig_path.write_bytes(signature_bytes)
        man_path.write_bytes(manifest_bytes)
        run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(key_path),
                "-signature",
                str(sig_path),
                str(man_path),
            ]
        )


def validate_external_anchor(anchor_status: Any, commitment: str, release_mode: bool) -> None:
    if not release_mode:
        return
    if not isinstance(anchor_status, dict):
        fail("release mode requires structured external anchor metadata")
    if anchor_status.get("type") != "external-anchor-v1":
        fail("external_publication.type must be external-anchor-v1")
    uri = anchor_status.get("uri")
    if not isinstance(uri, str) or not ANCHOR_URI.fullmatch(uri):
        fail("external_publication.uri must be https:// or urn: anchor")
    published_at = anchor_status.get("published_at")
    if not isinstance(published_at, str) or not RFC3339_Z.fullmatch(published_at):
        fail("external_publication.published_at must be UTC RFC3339 seconds")
    anchor_commitment = require_hex64(
        "external_publication.commitment_sha256",
        anchor_status.get("commitment_sha256"),
    )
    if anchor_commitment != commitment:
        fail("external_publication.commitment_sha256 must match anchor commitment")


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
    # P1: release-candidate always requires --release-mode and its trust checks.
    if profile == "release-candidate":
        if not release_mode:
            fail("profile=release-candidate requires --release-mode")
        if not isinstance(repo_commit, str) or not HEX40.fullmatch(repo_commit):
            fail("release mode requires repo_commit to be a concrete 40-hex commit")
        git_run(["rev-parse", "--verify", f"{repo_commit}^{{commit}}"], cwd=repo_root)
    elif release_mode:
        fail("release mode requires profile=release-candidate")
    else:
        if profile != "test-only-fixture":
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
    snapshot_path = require_repo_relative_path("snapshot.path", snapshot_path)
    snapshot_full = repo_root / snapshot_path
    if not snapshot_full.is_file():
        fail(f"snapshot file not found: {snapshot_path}", 2)
    snapshot_resolved = snapshot_full.resolve()
    try:
        snapshot_resolved.relative_to(repo_root)
    except ValueError:
        fail(f"snapshot path escapes repository: {snapshot_path}")
    if snapshot_full.is_symlink():
        fail(f"snapshot path must not be a symlink: {snapshot_path}")
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
    if release_mode and (
        anchor_status is None
        or (isinstance(anchor_status, str) and anchor_status in {"not_published_test_fixture", "not_published"})
    ):
        fail("release mode requires an externally published anchor reference")
    commitment = require_hex64("anchor.commitment_sha256", anchor.get("commitment_sha256"))
    actual_commitment = sha256_bytes(expected_anchor_preimage(manifest))
    if actual_commitment != commitment:
        fail(f"anchor commitment mismatch: {actual_commitment}")
    validate_external_anchor(anchor_status, commitment, release_mode)

    if release_mode:
        snapshot_blob_sha = git_blob_sha256(repo_root, ref, snapshot_path)
        if snapshot_blob_sha != snapshot_sha:
            fail(f"snapshot Git blob hash mismatch for {snapshot_path}: {snapshot_blob_sha}")


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
    parser.add_argument(
        "--expected-public-key-sha256",
        help="Release-mode trust root: expected SHA-256 of the public key bytes.",
    )
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    signature_path = Path(args.signature)
    public_key_path = Path(args.public_key)
    repo_root = Path(args.repo_root).resolve()
    if not manifest_path.is_file():
        fail(f"manifest file not found: {manifest_path}", 2)
    if not signature_path.is_file():
        fail(f"signature file not found: {signature_path}", 2)
    if not public_key_path.is_file():
        fail(f"public key file not found: {public_key_path}", 2)

    # Read all trusted inputs once. Signature verification uses only these bytes.
    try:
        raw = manifest_path.read_bytes()
        signature_bytes = signature_path.read_bytes()
        public_key_bytes = public_key_path.read_bytes()
        manifest = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"manifest/key/signature is not readable as required: {exc}", 2)
    if not isinstance(manifest, dict):
        fail("manifest root must be an object")

    verify_signature_bytes(
        raw,
        signature_bytes,
        public_key_bytes,
        args.release_mode,
        args.expected_public_key_sha256,
    )
    validate_manifest(manifest, repo_root, args.release_mode)
    print("Release manifest VALID")
    print(f"Manifest SHA-256: {sha256_bytes(raw)}")
    print("Boundary: internal snapshot consistency only; no public or assurance-grade release claim.")


if __name__ == "__main__":
    main()
