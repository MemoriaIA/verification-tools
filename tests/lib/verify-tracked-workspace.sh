#!/usr/bin/env bash
# Fail-closed helper for proving a checked-out workspace file equals its Git blob.

verify_tracked_workspace_file() {
  path="${1:-}"
  if [ -z "$path" ]; then
    echo "G-19 FAIL: verify_tracked_workspace_file requires a path"
    exit 1
  fi

  checkout_sha="${VT_G19_CHECKOUT_SHA:-}"
  if [ -z "$checkout_sha" ]; then
    checkout_sha="$(git rev-parse HEAD)"
  fi
  if ! printf '%s\n' "$checkout_sha" | grep -qE '^[0-9a-f]{40}$'; then
    echo "G-19 FAIL: checkout SHA is invalid for workspace verification ($checkout_sha)"
    exit 1
  fi
  if [ ! -f "$path" ]; then
    echo "G-19 FAIL: tracked workspace file is missing ($path)"
    exit 1
  fi

  disk_sha="$(sha256sum "$path" | awk '{print $1}')"
  blob_sha="$(git cat-file blob "$checkout_sha:$path" | sha256sum | awk '{print $1}')"
  if [ "$disk_sha" != "$blob_sha" ]; then
    echo "G-19 FAIL: workspace file differs from committed blob ($path)"
    exit 1
  fi
}
