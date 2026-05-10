#!/bin/bash
# local_setup.sh — update your local SSH config to point at a new RunPod instance.
# Run this on your Mac each time you spin up a fresh pod.
#
# Usage:
#   bash local_setup.sh <ip>:<port>
#
# Example:
#   bash local_setup.sh 203.0.113.42:22042

set -eo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: bash local_setup.sh <ip>:<port>" >&2
  exit 1
fi

HOST_PORT="$1"
IP="${HOST_PORT%%:*}"
PORT="${HOST_PORT##*:}"

if [ "$IP" = "$HOST_PORT" ] || [ -z "$PORT" ]; then
  echo "Error: argument must be in <ip>:<port> format, e.g. 203.0.113.42:22042" >&2
  exit 1
fi

# Remove any existing Host runpod block. Uses Python to match the block
# structurally so it's safe regardless of whether runpod is the last entry
# in the file (the sed range approach silently deletes everything after the
# block if there's no following Host line).
python3 -c "
import re, pathlib
p = pathlib.Path.home() / '.ssh/config'
txt = p.read_text() if p.exists() else ''
txt = re.sub(r'(?m)^Host runpod\n(?:[ \t]+.*\n)*', '', txt)
p.write_text(txt)
"

mkdir -p ~/.ssh
chmod 700 ~/.ssh

cat >> ~/.ssh/config << EOF

Host runpod
    HostName $IP
    Port $PORT
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

echo "Updated runpod -> $IP:$PORT"
echo "Connect with:  ssh runpod"
