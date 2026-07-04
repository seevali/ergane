#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE_LOOP="${REPO_ROOT}/scripts/ralph-loop.sh"
SOURCE_WATCH="${REPO_ROOT}/scripts/ralph-watch.sh"
SOURCE_PROMPTS="${REPO_ROOT}/scripts/prompts"
DEST_TEMPLATE="${REPO_ROOT}/installer/templates/loop"
DEST_LOOP="${DEST_TEMPLATE}/ralph-loop.sh"
DEST_WATCH="${DEST_TEMPLATE}/ralph-watch.sh"
DEST_PROMPTS="${DEST_TEMPLATE}/prompts"

sync_mode() {
  if [[ ! -f "$SOURCE_LOOP" ]]; then
    echo "Error: source loop script not found: $SOURCE_LOOP" >&2
    return 1
  fi
  if [[ ! -f "$SOURCE_WATCH" ]]; then
    echo "Error: source watch script not found: $SOURCE_WATCH" >&2
    return 1
  fi
  if [[ ! -d "$SOURCE_PROMPTS" ]]; then
    echo "Error: source prompts directory not found: $SOURCE_PROMPTS" >&2
    return 1
  fi

  mkdir -p "$DEST_TEMPLATE"

  cp -p "$SOURCE_LOOP" "$DEST_LOOP" || {
    echo "Error: failed to copy loop script" >&2
    return 1
  }

  cp -p "$SOURCE_WATCH" "$DEST_WATCH" || {
    echo "Error: failed to copy watch script" >&2
    return 1
  }

  rm -rf "$DEST_PROMPTS"

  cp -rp "$SOURCE_PROMPTS" "$DEST_PROMPTS" || {
    echo "Error: failed to copy prompts directory" >&2
    return 1
  }
}

check_mode() {
  local drift=0

  # ── Single-file scripts: loop + watch ──
  local pair src dest
  for pair in "${SOURCE_LOOP}::${DEST_LOOP}" "${SOURCE_WATCH}::${DEST_WATCH}"; do
    src="${pair%%::*}"
    dest="${pair##*::}"
    if [[ ! -f "$dest" ]]; then
      echo "Drift detected: $dest is missing (source: $src)" >&2
      drift=1
      continue
    fi
    if ! cmp -s "$src" "$dest"; then
      echo "Drift detected: $dest differs from source" >&2
      drift=1
    fi
  done

  # ── Prompts tree ──
  if [[ ! -d "$DEST_PROMPTS" ]]; then
    echo "Drift detected: synced prompts directory is missing: $DEST_PROMPTS" >&2
    drift=1
  else
    local src_file dest_file
    while IFS= read -r -d '' src_file; do
      dest_file="${src_file#"$SOURCE_PROMPTS"}"
      dest_file="${DEST_PROMPTS}${dest_file}"

      if [[ ! -f "$dest_file" ]]; then
        echo "Drift detected: $dest_file is missing (source: $src_file)" >&2
        drift=1
      elif ! cmp -s "$src_file" "$dest_file"; then
        echo "Drift detected: $dest_file differs from source" >&2
        drift=1
      fi
    done < <(find "$SOURCE_PROMPTS" -type f -print0)
  fi

  if [[ "$drift" -ne 0 ]]; then
    echo "Run 'installer/scripts/sync-templates.sh' to resync." >&2
    return 1
  fi

  return 0
}

main() {
  local mode="sync"

  if [[ $# -gt 0 ]]; then
    case "$1" in
      --check)
        mode="check"
        ;;
      --sync)
        mode="sync"
        ;;
      --help)
        echo "Usage: installer/scripts/sync-templates.sh [--check|--sync|--help]"
        echo ""
        echo "Sync canonical loop files into the installer package."
        echo ""
        echo "Modes:"
        echo "  --sync   (default) Copy scripts/ralph-loop.sh, scripts/ralph-watch.sh and"
        echo "           scripts/prompts/ into installer/templates/loop/"
        echo "  --check  Exit non-zero if any synced file differs from the source"
        echo "           (each drifted file is named on stderr)"
        echo "  --help   Show this message"
        return 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        echo "Run with --help for usage" >&2
        return 1
        ;;
    esac
  fi

  case "$mode" in
    sync)
      sync_mode
      ;;
    check)
      check_mode
      ;;
  esac
}

main "$@"
