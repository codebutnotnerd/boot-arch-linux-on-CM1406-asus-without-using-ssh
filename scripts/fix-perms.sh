#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--check | --git]"
  echo "  --check  Verify tracked shell scripts have executable Git and filesystem modes."
  echo "  --git    Set executable filesystem and Git index modes for tracked shell scripts."
}

mode="check"
case "${1:---check}" in
  --check) mode="check" ;;
  --git) mode="git" ;;
  -h|--help) usage; exit 0 ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

mapfile -d '' repository_files < <(git ls-files -co --exclude-standard -z)
scripts=()
for path in "${repository_files[@]}"; do
  [[ "$path" == *.sh ]] && scripts+=("$path")
done
if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "No tracked shell scripts found."
  exit 0
fi

failed=0
for script in "${scripts[@]}"; do
  if [[ ! -f "$script" ]]; then
    echo "Missing tracked script: $script" >&2
    failed=1
    continue
  fi

  if [[ "$mode" == git ]]; then
    chmod +x "$script"
    if git ls-files --error-unmatch -- "$script" >/dev/null 2>&1; then
      git update-index --chmod=+x -- "$script"
    fi
  else
    index_mode="$(git ls-files -s -- "$script" | awk 'NR == 1 { print $1 }')"
    if [[ ! -x "$script" || ( -n "$index_mode" && "$index_mode" != "100755" ) ]]; then
      echo "Not executable in filesystem and/or Git index: $script (index mode: ${index_mode:-untracked})" >&2
      failed=1
    fi
  fi
done

if [[ "$mode" == git ]]; then
  echo "Updated executable permissions for ${#scripts[@]} tracked shell scripts."
elif [[ "$failed" -ne 0 ]]; then
  exit 1
else
  echo "All ${#scripts[@]} tracked shell scripts are executable."
fi
