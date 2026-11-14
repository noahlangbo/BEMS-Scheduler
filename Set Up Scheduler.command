#!/bin/bash
# Set up the downloaded block folder in place; never replace an existing setup.
set -euo pipefail

pause() { printf '\nPress Return to close this window... '; read -r _answer || true; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
stage=''
finish() {
  status=$?
  trap - EXIT
  if [[ -n "$stage" && -d "$stage" ]]; then rm -rf -- "$stage"; fi
  if (( status != 0 )); then printf '\nSetup did not complete. Existing block files were not replaced.\n' >&2; fi
  pause
  exit "$status"
}
trap finish EXIT

source_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || fail 'Cannot locate the extracted project folder.'
[[ -f "$source_dir/main.py" && -f "$source_dir/editor.py" && -f "$source_dir/editor.html" && -f "$source_dir/requirements.txt" && -f "$source_dir/config.json" ]] || fail 'Required project files are missing. Extract the complete repository first.'
[[ ! -e "$source_dir/.venv" && ! -L "$source_dir/.venv" ]] || fail "This folder is already set up. For a new block, download and extract a fresh copy. Existing data was not changed."
printf 'Setting up this block folder:\n  %s\n\n' "$source_dir"
printf 'The editor, configuration, inputs and outputs stay in this folder.\n'
printf 'Internet access is needed for Python dependencies and, if needed, a private Python runtime.\n\n'
printf 'Continue? [y/N] '
read -r answer || fail 'No answer received.'
[[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { printf 'Canceled.\n'; exit 0; }
stage=$(mktemp -d "$source_dir/.bems-setup.XXXXXXXX") || fail 'Could not create a temporary setup folder.'
chmod +x "$source_dir"/*.command || fail 'Could not set launcher permissions.'
printf '\nChecking for Python 3.11, 3.12, or 3.13...\n'

setup_environment() {
  local python_exe="$1"
  rm -rf -- "$stage/.venv"
  if ! "$python_exe" -m venv "$stage/.venv"; then
    printf 'Could not create a virtual environment with %s.\n' "$python_exe" >&2
    rm -rf -- "$stage/.venv"
    return 1
  fi
  # Binary wheels only: never run a dependency source build. Pip alone contacts its configured index.
  if "$stage/.venv/bin/python" -m pip install --only-binary=:all: -r "$source_dir/requirements.txt"; then
    printf 'Dependencies installed.\n'
    return 0
  fi
  printf 'Pinned binary packages could not be installed with %s.\n' "$python_exe" >&2
  rm -rf -- "$stage/.venv"
  return 1
}

# If no suitable Python is already available, install a pinned, checksum-verified
# standalone runtime inside this block folder. This does not
# modify macOS, PATH, shell profiles, or require administrator privileges.
ensure_private_python() {
  local machine arch filename url checksum runtime_parent runtime_dir temp_dir
  machine=$(uname -m)
  case "$machine" in
    arm64|aarch64) arch='aarch64' ;;
    x86_64) arch='x86_64' ;;
    *) printf 'Automatic Python setup supports Apple Silicon (arm64) and Intel (x86_64), not %s.\n' "$machine" >&2; return 1 ;;
  esac
  filename="cpython-3.13.16+20261009-${arch}-apple-darwin-install_only_stripped.tar.gz"
  case "$arch" in
    aarch64) checksum='11785155d0f70e634178219c20925d8f20be00a3da4684fc4f5019dd15602ef7' ;;
    x86_64) checksum='bd085c51e960f00ee33b630e2b13ac90fe90cdc3da25a0f0bc0719b1294920bf' ;;
  esac
  url="https://github.com/astral-sh/python-build-standalone/releases/download/20261009/${filename/+/%2B}"
  runtime_parent="$source_dir/.runtime"
  runtime_dir="$runtime_parent/cpython-3.13.16-20261009-${arch}"
  mkdir -p -- "$runtime_parent" || { printf 'Could not create the per-user Python runtime folder: %s\n' "$runtime_parent" >&2; return 1; }

  if [[ -e "$runtime_dir" || -L "$runtime_dir" ]]; then
    if [[ ! -f "$runtime_dir/bin/python3.13" || ! -f "$runtime_dir/.bems-python-sha256" ]] || \
       [[ "$(cat "$runtime_dir/.bems-python-sha256" 2>/dev/null)" != "$checksum" ]] || \
       ! "$runtime_dir/bin/python3.13" -c 'import sys; raise SystemExit(sys.version_info[:3] != (3,13,16))' >/dev/null 2>&1; then
      printf 'A Python runtime path already exists but is not the expected verified runtime: %s\n' "$runtime_dir" >&2
      printf 'Nothing was replaced. Inspect or move that folder yourself, then rerun.\n' >&2
      return 1
    fi
    PRIVATE_PYTHON="$runtime_dir/bin/python3.13"
    printf 'Reusing verified private Python 3.13.16 at %s\n' "$PRIVATE_PYTHON"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || { printf 'curl is required to download the private Python runtime.\n' >&2; return 1; }
  command -v shasum >/dev/null 2>&1 || { printf 'shasum is required to verify the private Python runtime.\n' >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { printf 'tar is required to unpack the private Python runtime.\n' >&2; return 1; }
  temp_dir=$(mktemp -d "$runtime_parent/.python-runtime.XXXXXXXX") || { printf 'Could not create a temporary runtime folder.\n' >&2; return 1; }
  printf '\nNo existing Python completed setup. Downloading private Python 3.13.16 for %s...\n' "$machine"
  if ! curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 20 "$url" -o "$temp_dir/python.tar.gz"; then
    rm -rf -- "$temp_dir"
    printf 'Python download failed. Check your internet connection and try again.\n' >&2
    return 1
  fi
  if ! (cd "$temp_dir" && printf '%s  %s\n' "$checksum" python.tar.gz | shasum -a 256 -c -); then
    rm -rf -- "$temp_dir"
    printf 'Python archive checksum did not match. The archive was not installed.\n' >&2
    return 1
  fi
  if ! tar -xzf "$temp_dir/python.tar.gz" -C "$temp_dir" || \
     [[ ! -x "$temp_dir/python/bin/python3.13" ]] || \
     ! "$temp_dir/python/bin/python3.13" -c 'import sys; raise SystemExit(sys.version_info[:3] != (3,13,16))' >/dev/null 2>&1; then
    rm -rf -- "$temp_dir"
    printf 'The verified Python archive did not contain a usable Python 3.13.16 runtime.\n' >&2
    return 1
  fi
  printf '%s\n' "$checksum" > "$temp_dir/python/.bems-python-sha256"
  if ! mv -n -- "$temp_dir/python" "$runtime_dir" || [[ -e "$temp_dir/python" ]]; then
    rm -rf -- "$temp_dir"
    printf 'Could not install the private Python runtime without replacing an existing path.\n' >&2
    return 1
  fi
  rm -rf -- "$temp_dir"
  PRIVATE_PYTHON="$runtime_dir/bin/python3.13"
  printf 'Installed verified private Python at %s\n' "$PRIVATE_PYTHON"
  return 0
}

installed=0
for candidate in python3.11 python3.12 python3.13 python3 \
  "$HOME/.aside/runtime/bin/python3.11" "$HOME/.aside/runtime/bin/python3.12" "$HOME/.aside/runtime/bin/python3.13" \
  /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.13 \
  /usr/local/bin/python3.11 /usr/local/bin/python3.12 /usr/local/bin/python3.13 \
  /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 \
  /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
  /Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13; do
  if [[ "$candidate" == */* ]]; then [[ -x "$candidate" ]] || continue
  else command -v "$candidate" >/dev/null 2>&1 || continue
  fi
  if ! "$candidate" -c 'import sys; raise SystemExit(not (sys.version_info[:2] in ((3,11),(3,12),(3,13))))' >/dev/null 2>&1; then continue; fi
  printf '\nTrying existing Python: %s (%s)\n' "$candidate" "$("$candidate" --version 2>&1)"
  if setup_environment "$candidate"; then installed=1; break; fi
done

if (( installed == 0 )); then
  ensure_private_python || fail 'Could not install a verified private Python runtime.'
  setup_environment "$PRIVATE_PYTHON" || fail 'Python is ready, but the pinned binary dependencies could not be installed. Check the pip messages above and retry when the package index is reachable.'
fi

# Keep the environment and every block-specific artifact inside this folder.
[[ ! -e "$source_dir/.venv" && ! -L "$source_dir/.venv" ]] || fail 'An environment appeared during setup; nothing was replaced.'
mv -n -- "$stage/.venv" "$source_dir/.venv" || fail 'Could not place the environment in the block folder.'
[[ ! -e "$stage/.venv" ]] || fail 'An environment appeared during setup; nothing was replaced.'
rm -rf -- "$stage"
stage=''
mkdir -p -- "$source_dir/inputs" "$source_dir/outputs" || fail 'Could not create input and output folders.'
printf '\nReady: %s\n' "$source_dir"
printf 'Use Open BEMS Editor.command and Run Scheduler.command in this folder.\n'
printf 'Put this block’s CSV in inputs, and find generated files in outputs.\n'
