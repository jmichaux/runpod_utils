#!/bin/bash
# local_pf.sh — forward a local port to the runpod instance.
# Requires local_setup.sh to have been run first.
#
# Usage:
#   bash local_pf.sh [local_port] [remote_port]
#
# Examples:
#   bash local_pf.sh              -> forwards localhost:8080 to pod:8080
#   bash local_pf.sh 8888         -> forwards localhost:8888 to pod:8888
#   bash local_pf.sh 8080 8888    -> forwards localhost:8080 to pod:8888

set -eo pipefail

LPORT="${1:-8080}"
RPORT="${2:-$LPORT}"

# Verify the runpod alias exists before trying to connect.
if ! grep -q "^Host runpod$" ~/.ssh/config 2>/dev/null; then
  echo "Error: no 'runpod' host found in ~/.ssh/config." >&2
  echo "Run local_setup.sh first:  bash local_setup.sh <ip>:<port>" >&2
  exit 1
fi

echo "Forwarding localhost:$LPORT -> runpod:$RPORT"
echo "Press Ctrl+C to stop."
ssh -L "${LPORT}:localhost:${RPORT}" runpod
