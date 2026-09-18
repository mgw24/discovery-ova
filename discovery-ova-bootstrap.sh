#!/usr/bin/env bash
set -Eeuo pipefail

# Discovery-OVA bootstrap updater
# Defaults point to the Discovery-OVA GitHub repository.
# Override any value through the environment if needed.

GITHUB_OWNER="${GITHUB_OWNER:-mgw24}"
GITHUB_REPO="${GITHUB_REPO:-discovery-ova}"
GITHUB_REF="${GITHUB_REF:-main}"
SCRIPT_NAME="${SCRIPT_NAME:-discovery-ova-install.sh}"
INSTALL_ACTION="${INSTALL_ACTION:-install}"

if [[ -z "$GITHUB_OWNER" || -z "$GITHUB_REPO" || -z "$GITHUB_REF" ]]; then
  echo "ERROR: GitHub owner, repository, and ref must not be empty." >&2
  exit 2
fi

RAW_BASE="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/refs/heads/${GITHUB_REF}"
SCRIPT_URL="${RAW_BASE}/${SCRIPT_NAME}"
SUMS_URL="${RAW_BASE}/SHA256SUMS"
TMP_DIR="$(mktemp -d /tmp/discovery-ova-bootstrap.XXXXXX)"
DOWNLOADED_SCRIPT="${TMP_DIR}/${SCRIPT_NAME}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Discovery-OVA bootstrap"
echo "Repository : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Ref        : ${GITHUB_REF}"
echo "Installer  : ${SCRIPT_URL}"
echo

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 10 "$SCRIPT_URL" -o "$DOWNLOADED_SCRIPT"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$DOWNLOADED_SCRIPT" "$SCRIPT_URL"
else
  echo "ERROR: curl or wget is required." >&2
  exit 3
fi

chmod +x "$DOWNLOADED_SCRIPT"

ACTUAL_SHA256="$(sha256sum "$DOWNLOADED_SCRIPT" | awk '{print $1}')"
echo "Downloaded SHA-256: $ACTUAL_SHA256"

# If the repository publishes SHA256SUMS, verify against it.
SUMS_FILE="${TMP_DIR}/SHA256SUMS"
if command -v curl >/dev/null 2>&1; then
  curl -fsL --connect-timeout 10 "$SUMS_URL" -o "$SUMS_FILE" 2>/dev/null || true
else
  wget -q -O "$SUMS_FILE" "$SUMS_URL" 2>/dev/null || true
fi

if [[ -s "$SUMS_FILE" ]] && grep -Eq "[[:space:]](\*|)${SCRIPT_NAME}$" "$SUMS_FILE"; then
  EXPECTED_SHA256="$(awk -v f="$SCRIPT_NAME" '$2==f || $2=="*"f {print $1; exit}' "$SUMS_FILE")"
  if [[ -n "$EXPECTED_SHA256" ]]; then
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
      echo "ERROR: SHA-256 verification failed." >&2
      echo "Expected: $EXPECTED_SHA256" >&2
      echo "Actual  : $ACTUAL_SHA256" >&2
      exit 4
    fi
    echo "SHA-256 verification: OK"
  fi
else
  echo "WARNING: No matching SHA256SUMS entry found; continuing with displayed hash."
fi

echo
read -r -p "Run the downloaded Discovery-OVA installer now? [Y/n]: " answer
answer="${answer:-Y}"
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "Installer left at: $DOWNLOADED_SCRIPT"
  trap - EXIT
  exit 0
fi

echo
if [[ $EUID -eq 0 ]]; then
  exec "$DOWNLOADED_SCRIPT" "$INSTALL_ACTION"
else
  exec sudo "$DOWNLOADED_SCRIPT" "$INSTALL_ACTION"
fi
