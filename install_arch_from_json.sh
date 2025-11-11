#!/usr/bin/env bash
# install_arch_from_json.sh
# Install Arch Linux packages by category from a JSON file generated for post-install.
# Requires: pacman, jq. Optional: yay (for AUR installs).
#
# Usage:
#   sudo ./install_arch_from_json.sh -f arch_post_install.json [--categories "base_system,networking"] [--aur] [--dry-run] [--no-confirm]
#
# Examples:
#   sudo ./install_arch_from_json.sh -f arch_post_install.json
#   sudo ./install_arch_from_json.sh -f arch_post_install.json --categories "system_admin,networking,cybersecurity" --aur
#
set -euo pipefail
IFS=$'\n\t'

JSON_FILE=""
CATEGORIES_FILTER=""
ENABLE_AUR=false
DRY_RUN=false
NO_CONFIRM=false

have_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Install Arch packages by category from a JSON manifest.

Required:
  -f, --file <path>            Path to JSON (e.g., arch_post_install.json)

Optional:
  --categories "a,b,c"         Comma-separated subset of categories to install
  --aur                        Attempt to install missing/non-repo packages via yay if present
  --dry-run                    Show what would be installed, but don't install
  --no-confirm                 Pass --noconfirm to pacman/yay

Examples:
  sudo $0 -f arch_post_install.json
  sudo $0 -f arch_post_install.json --categories "system_admin,networking,cybersecurity" --aur
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) JSON_FILE="${2:-}"; shift 2;;
    --categories) CATEGORIES_FILTER="${2:-}"; shift 2;;
    --aur) ENABLE_AUR=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --no-confirm) NO_CONFIRM=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

if [[ -z "$JSON_FILE" ]]; then
  echo "Error: JSON file not provided."; usage; exit 1
fi
if [[ ! -f "$JSON_FILE" ]]; then
  echo "Error: JSON file '$JSON_FILE' not found."; exit 1
fi

if ! have_cmd pacman; then
  echo "Error: pacman not found. This script is for Arch Linux."; exit 1
fi

# Ensure jq exists
if ! have_cmd jq; then
  echo "jq not found. Installing jq..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] pacman -S --needed jq"
  else
    if [[ "$NO_CONFIRM" == true ]]; then
      pacman -S --needed --noconfirm jq
    else
      pacman -S --needed jq
    fi
  fi
fi

# Build category list
if [[ -n "$CATEGORIES_FILTER" ]]; then
  IFS=',' read -r -a CATEGORIES <<< "$CATEGORIES_FILTER"
else
  mapfile -t CATEGORIES < <(jq -r 'keys[]' "$JSON_FILE")
fi

echo "Categories to process: ${CATEGORIES[*]}"

# Accumulators
PACMAN_INSTALL=()
AUR_INSTALL=()
SKIPPED_ALREADY_INSTALLED=()
MISSING_NO_AUR=()

is_installed() { pacman -Qq "$1" >/dev/null 2>&1; }
is_in_repo() { pacman -Si "$1" >/dev/null 2>&1; }

if [[ "$ENABLE_AUR" == true ]]; then
  if ! have_cmd yay; then
    echo "Warning: --aur specified but 'yay' is not installed. AUR packages will be queued as missing."
  fi
fi

# Iterate categories and decide where each package should go
for cat in "${CATEGORIES[@]}"; do
  echo "Processing category: $cat"
  if ! jq -e --arg c "$cat" 'has($c)' "$JSON_FILE" >/dev/null; then
    echo "  Skipping unknown category: $cat"
    continue
  fi
  mapfile -t pkgs < <(jq -r --arg c "$cat" '.[$c].packages[]' "$JSON_FILE")

  for p in "${pkgs[@]}"; do
    if is_installed "$p"; then
      SKIPPED_ALREADY_INSTALLED+=("$p")
      continue
    fi
    if is_in_repo "$p"; then
      PACMAN_INSTALL+=("$p")
    else
      if [[ "$ENABLE_AUR" == true && "$(command -v yay)" ]]; then
        AUR_INSTALL+=("$p")
      else
        MISSING_NO_AUR+=("$p")
      fi
    fi
  done
done

# De-duplicate arrays
dedup() {
  awk '!seen[$0]++'
}
mapfile -t PACMAN_INSTALL < <(printf "%s\n" "${PACMAN_INSTALL[@]:-}" | dedup || true)
mapfile -t AUR_INSTALL    < <(printf "%s\n" "${AUR_INSTALL[@]:-}"    | dedup || true)
mapfile -t SKIPPED_ALREADY_INSTALLED < <(printf "%s\n" "${SKIPPED_ALREADY_INSTALLED[@]:-}" | dedup || true)
mapfile -t MISSING_NO_AUR < <(printf "%s\n" "${MISSING_NO_AUR[@]:-}" | dedup || true)

echo "Summary:"
echo "  Already installed: ${#SKIPPED_ALREADY_INSTALLED[@]}"
echo "  Repo (pacman) install: ${#PACMAN_INSTALL[@]}"
echo "  AUR (yay) install: ${#AUR_INSTALL[@]}"
echo "  Missing (no AUR): ${#MISSING_NO_AUR[@]}"

if [[ "${#SKIPPED_ALREADY_INSTALLED[@]}" -gt 0 ]]; then
  echo "  Skipped: ${SKIPPED_ALREADY_INSTALLED[*]}"
fi

# Perform installs
if [[ "${#PACMAN_INSTALL[@]}" -gt 0 ]]; then
  echo "Installing repo packages with pacman..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] pacman -S --needed ${NO_CONFIRM:+--noconfirm} ${PACMAN_INSTALL[*]}"
  else
    if [[ "$NO_CONFIRM" == true ]]; then
      pacman -S --needed --noconfirm "${PACMAN_INSTALL[@]}"
    else
      pacman -S --needed "${PACMAN_INSTALL[@]}"
    fi
  fi
fi

if [[ "${#AUR_INSTALL[@]}" -gt 0 ]]; then
  if ! have_cmd yay; then
    echo "AUR packages requested but 'yay' not found. You can install yay, then re-run with --aur."
    echo "Missing AUR candidates: ${AUR_INSTALL[*]}"
  else
    echo "Installing AUR packages with yay..."
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] yay -S --needed ${NO_CONFIRM:+--noconfirm} ${AUR_INSTALL[*]}"
    else
      if [[ "$NO_CONFIRM" == true ]]; then
        yay -S --needed --noconfirm "${AUR_INSTALL[@]}"
      else
        yay -S --needed "${AUR_INSTALL[@]}"
      fi
    fi
  fi
fi

if [[ "${#MISSING_NO_AUR[@]}" -gt 0 ]]; then
  echo "These packages were not found in repos and AUR install was not enabled/available:"
  echo "  ${MISSING_NO_AUR[*]}"
fi

echo "Done."
