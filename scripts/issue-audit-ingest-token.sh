#!/usr/bin/env bash
set -euo pipefail

if command -v openssl >/dev/null 2>&1; then
  openssl rand -hex 24
  exit 0
fi

# Fallback for environments without openssl.
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
