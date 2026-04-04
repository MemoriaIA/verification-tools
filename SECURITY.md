# Security Policy

## Scope

This repository contains:

- The public vault schema for MemoriaIA (`schema/`)
- Append-only enforcement triggers (`schema/append-only-triggers.sql`)
- Independent hash-chain verification scripts (`verify/`)
- Example fixture data (`fixtures/`)

This repository does **not** contain the MemoriaIA product, its services, encryption implementation, or any key material. Security reports about product internals should be directed to the private product security contact.

## Supported Versions

This repository tracks the current published verification tooling. There are no versioned releases — the `main` branch is authoritative.

## Reporting a Vulnerability

If you discover a vulnerability in this repository — for example:

- A flaw in the hash-chain verification logic that would allow a tampered chain to pass as valid
- An error in the mathematical specification that contradicts the implementation
- A bug in the example fixture that produces incorrect verification output

Please report it by opening a **private security advisory** on this repository, or by emailing:

**security@alekore.com**

Include:

1. A description of the issue
2. Steps to reproduce (if applicable)
3. Your assessment of impact
4. Any suggested fix

We will acknowledge receipt within 48 hours and aim to resolve confirmed vulnerabilities within 14 days.

## What Is NOT in Scope

- Vulnerabilities in the MemoriaIA product itself (report to private product security contact)
- Social engineering
- Denial-of-service against any hosted service
- Issues that require physical access to a user's device

## Disclosure Policy

We follow coordinated disclosure. Please allow reasonable time for a fix to be published before public disclosure.
