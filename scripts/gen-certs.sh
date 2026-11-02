#!/usr/bin/env bash
# Generate a self-signed TLS certificate for nginx.
#
# Usage: scripts/gen-certs.sh [extra-ip-or-dns ...]
#   scripts/gen-certs.sh 192.168.1.50        # add the VM's IP to the cert
#
# Writes nginx/certs/selfsigned.{crt,key} (gitignored). The cert always covers
# localhost and 127.0.0.1; pass the VM's IP/hostname so browsers on your PC
# match it. Re-run any time to renew (valid DAYS days), then restart nginx.
set -euo pipefail

DAYS="${DAYS:-365}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${CERT_DIR:-$REPO_ROOT/nginx/certs}"

mkdir -p "$CERT_DIR"

# Build the subjectAltName list: localhost + 127.0.0.1 + anything passed in.
san="DNS:localhost,IP:127.0.0.1"
for name in "$@"; do
  if [[ "$name" =~ ^[0-9.]+$ ]]; then
    san+=",IP:$name"
  else
    san+=",DNS:$name"
  fi
done

# MSYS2_ARG_CONV_EXCL stops Git Bash on Windows from rewriting "/CN=..." into a
# file path; it has no effect on Linux.
MSYS2_ARG_CONV_EXCL="/CN" openssl req -x509 -nodes -newkey rsa:2048 \
  -days "$DAYS" \
  -keyout "$CERT_DIR/selfsigned.key" \
  -out "$CERT_DIR/selfsigned.crt" \
  -subj "/CN=ultradoc.local" \
  -addext "subjectAltName=$san"

# nginx reads the key as root before dropping privileges; keep it private.
chmod 600 "$CERT_DIR/selfsigned.key"
chmod 644 "$CERT_DIR/selfsigned.crt"

echo "Wrote $CERT_DIR/selfsigned.crt (SAN: $san, valid $DAYS days)"
