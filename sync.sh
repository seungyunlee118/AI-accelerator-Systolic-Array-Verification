#!/usr/bin/env bash
# Copy this repo from the Mac to the Xcelium server (ssh alias "msd10"; needs the UH VPN).
# Edit on the Mac, run ./sync.sh, then run xrun in the server terminal.
# Nothing on the server is deleted, so simulation outputs there are kept.
set -euo pipefail
cd "$(dirname "$0")"
REMOTE_DIR=AI-accelerator-Systolic-Array-Verification
if ! ssh -o BatchMode=yes msd10 true 2>/dev/null; then
  echo "Cannot reach msd10. Is the UH VPN connected?" >&2
  exit 1
fi
rsync -az --exclude .git/ --exclude .DS_Store ./ "msd10:${REMOTE_DIR}/"
echo "synced -> msd10:~/${REMOTE_DIR}"
