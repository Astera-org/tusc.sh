#!/usr/bin/env bash
#
# Run test/test.sh inside a Lima-managed Linux VM, from a macOS host.
#
# Usage:
#   test/run-lima.sh           # start (if needed) and run the test
#   test/run-lima.sh --clean   # start, run the test, then delete the VM
#
# Requires: limactl (brew install lima).
#
set -eu
set -o pipefail

VM_NAME="${LIMA_VM_NAME:-tusc-test}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/test/lima.yaml"
GENERATED_YAML="$(mktemp -t lima-tusc.XXXXXXXX).yaml"

CLEAN=0
case "${1:-}" in
  --clean) CLEAN=1 ;;
  "") ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

command -v limactl >/dev/null 2>&1 || {
  echo "limactl not found. Install with: brew install lima" >&2
  exit 1
}

# Materialize a yaml with the host repo path baked in.
sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$TEMPLATE" > "$GENERATED_YAML"

cleanup() {
  rm -f "$GENERATED_YAML"
  if [[ $CLEAN -eq 1 ]]; then
    limactl stop "$VM_NAME" 2>/dev/null || true
    limactl delete "$VM_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start the VM if it isn't already running.
if ! limactl list --format '{{.Name}}:{{.Status}}' 2>/dev/null \
     | grep -qx "$VM_NAME:Running"; then
  echo ">>> Starting Lima VM '$VM_NAME' (this can take a few minutes on first run)"
  if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$VM_NAME"; then
    limactl start --tty=false "$VM_NAME"
  else
    limactl start --tty=false --name="$VM_NAME" "$GENERATED_YAML"
  fi
fi

echo ">>> Running test/test.sh inside '$VM_NAME'"
# --workdir avoids the implicit "cd to host pwd" that Lima does by
# default. The repo mount is read-only so we point the tusd cache at
# /tmp inside the guest.
limactl shell --workdir=/repo "$VM_NAME" \
  env TUSC_CACHE_DIR=/tmp/tusc-cache bash test/test.sh
