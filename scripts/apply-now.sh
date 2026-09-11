#!/usr/bin/env bash
# Run on the Saltbox host as the Saltbox user (media), not as root.
# Reads WUD's update list and runs sb install for each matching role, now
# (ignores the 01:00–03:00 window used by the WUD trigger).
set -euo pipefail

SKIP="${SB_INSTALL_SKIP:-wud,arbor,arbor-vnc,arbour-fetcher,arbor-fetcher}"
CONTAINER="${WUD_CONTAINER:-wud}"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this as the Saltbox user (media), not root." >&2
  exit 1
fi

if [[ "$(id -un)" != "${SB_INSTALL_USER:-media}" ]]; then
  echo "Warning: running as $(id -un); Saltbox expects ${SB_INSTALL_USER:-media}." >&2
fi

command -v python3 >/dev/null
command -v sb >/dev/null
docker exec "$CONTAINER" wget -qO- http://127.0.0.1:3000/health >/dev/null

mapfile -t names < <(docker exec "$CONTAINER" wget -qO- http://127.0.0.1:3000/api/containers | python3 -c '
import json, sys
raw = sys.stdin.read()
data = json.loads(raw)
if isinstance(data, dict):
    data = data.get("containers") or data.get("data") or []
for c in data:
    if c.get("updateAvailable") is True:
        name = (c.get("name") or "").lstrip("/")
        if name:
            print(name)
')

if [[ ${#names[@]} -eq 0 ]]; then
  echo "WUD reports no containers with updateAvailable=true."
  exit 0
fi

echo "Pending updates (${#names[@]}): ${names[*]}"
echo

skipped=0
installed=0
failed=0
for name in "${names[@]}"; do
  case ",$SKIP," in
    *,"$name",*) echo "skip $name (skip list)"; skipped=$((skipped + 1)); continue ;;
  esac

  tag=""
  if [[ -d "/srv/git/saltbox/roles/${name}" ]]; then
    tag="$name"
  elif [[ -d "/opt/sandbox/roles/${name}" ]]; then
    tag="sandbox-${name}"
  else
    echo "skip $name (no Saltbox/sandbox role)"
    skipped=$((skipped + 1))
    continue
  fi

  echo ">>> sb install ${tag}"
  if sb install "$tag"; then
    installed=$((installed + 1))
  else
    echo "!!! sb install ${tag} failed (exit $?)" >&2
    failed=$((failed + 1))
  fi
done

echo
echo "Done. installed=${installed} skipped=${skipped} failed=${failed}"
