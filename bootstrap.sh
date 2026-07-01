#!/usr/bin/env bash
#
# fedora-setup bootstrap
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/keirfantasy/fedora-setup/main/bootstrap.sh | bash
#
# Pass options through with `-s --`, e.g.:
#   curl -fsSL https://raw.githubusercontent.com/keirfantasy/fedora-setup/main/bootstrap.sh | bash -s -- --desktop
#
# Downloads fedora-setup.sh to a temp file and runs it with the terminal
# attached, so sudo prompts still work even when this bootstrap is piped.
#
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/keirfantasy/fedora-setup/main/fedora-setup.sh"

command -v curl >/dev/null 2>&1 || {
  echo "error: curl is required" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Downloading fedora-setup.sh..."
curl -fsSL "$SCRIPT_URL" -o "$tmp"

# Run with the real terminal on stdin so sudo/prompts work when piped.
if [[ -t 0 ]]; then
  bash "$tmp" "$@"
elif [[ -e /dev/tty ]]; then
  bash "$tmp" "$@" </dev/tty
else
  echo "warning: no terminal available; sudo prompts may fail" >&2
  bash "$tmp" "$@"
fi
