#!/usr/bin/env bash
# Fail-closed helper for proving a checked-out workspace file equals its Git blob.

verify_tracked_workspace_file() {
  path="${1:-}"
  if [ -z "$path" ]; then
    echo "G-19 FAIL: verify_tracked_workspace_file requires a path"
    exit 1
  fi

  git_bin="${GIT_BIN:-git}"
  checkout_sha="${VT_G19_CHECKOUT_SHA:-}"
  if [ -z "$checkout_sha" ]; then
    checkout_sha="$("$git_bin" rev-parse HEAD)"
  fi
  if ! printf '%s\n' "$checkout_sha" | grep -qE '^[0-9a-f]{40}$'; then
    echo "G-19 FAIL: checkout SHA is invalid for workspace verification ($checkout_sha)"
    exit 1
  fi
  if [ ! -f "$path" ]; then
    echo "G-19 FAIL: tracked workspace file is missing ($path)"
    exit 1
  fi

  if ! "$git_bin" cat-file -e "$checkout_sha:$path" 2>/dev/null; then
    echo "G-19 FAIL: tracked workspace blob is missing ($checkout_sha:$path)"
    exit 1
  fi
  if ! "$git_bin" diff --cached --quiet -- "$path"; then
    echo "G-19 FAIL: staged workspace file differs from committed blob ($path)"
    exit 1
  fi
  expected_blob_id="$("$git_bin" rev-parse "$checkout_sha:$path")"
  worktree_blob_id="$("$git_bin" hash-object --path="$path" "$path")"
  if [ "$worktree_blob_id" != "$expected_blob_id" ]; then
    echo "G-19 FAIL: workspace file differs from committed blob after Git checkout filters ($path)"
    exit 1
  fi
}
