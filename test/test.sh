#!/usr/bin/env bash
#
# End-to-end test for tusc.sh.
# Works on macOS (stock /bin/bash 3.2) and Linux.
# Requires: curl, tar, awk, cmp, shasum (or sha256sum).
#
set -eu
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
# CACHE_DIR is overridable so the test can be driven against a read-only
# checkout (e.g. via Lima's read-only virtiofs mount).
CACHE_DIR="${TUSC_CACHE_DIR:-$TEST_DIR/.cache}"
TUSD_VERSION="${TUSD_VERSION:-v2.5.0}"
TUSD_PORT="${TUSD_PORT:-$((30000 + RANDOM % 20000))}"
TUSD_HOST="${TUSD_HOST:-127.0.0.1}"

WORK_DIR="$(mktemp -d -t tusc-test.XXXXXXXXXX)"
UPLOAD_DIR="$WORK_DIR/uploads"
mkdir -p "$UPLOAD_DIR"

# Isolate tusc's resume-state cache from any other invocation on this
# host so repeated runs are independent.
export TUSDIR="$WORK_DIR/tus-cache"

case "$(uname -s)" in
  Linux)  TUSD_OS=linux;  TUSD_EXT=tar.gz ;;
  Darwin) TUSD_OS=darwin; TUSD_EXT=zip ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) TUSD_ARCH=amd64 ;;
  aarch64|arm64) TUSD_ARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

TUSD_ASSET="tusd_${TUSD_OS}_${TUSD_ARCH}.${TUSD_EXT}"
TUSD_URL="https://github.com/tus/tusd/releases/download/${TUSD_VERSION}/${TUSD_ASSET}"
TUSD_DIR="$CACHE_DIR/tusd_${TUSD_OS}_${TUSD_ARCH}_${TUSD_VERSION}"
TUSD_BIN="$TUSD_DIR/tusd"

TUSD_PID=""
cleanup() {
  local rc=$?
  if [[ -n "$TUSD_PID" ]] && kill -0 "$TUSD_PID" 2>/dev/null; then
    kill "$TUSD_PID" 2>/dev/null || true
    wait "$TUSD_PID" 2>/dev/null || true
  fi
  if [[ $rc -ne 0 && -f "$WORK_DIR/tusd.log" ]]; then
    echo "----- tusd.log -----" >&2
    cat "$WORK_DIR/tusd.log" >&2
    echo "--------------------" >&2
  fi
  rm -rf "$WORK_DIR"
  exit $rc
}
trap cleanup EXIT

say() { printf '>>> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ ! -x "$TUSD_BIN" ]]; then
  say "Downloading tusd $TUSD_VERSION ($TUSD_OS/$TUSD_ARCH)"
  mkdir -p "$TUSD_DIR"
  curl -fsSLo "$CACHE_DIR/$TUSD_ASSET" "$TUSD_URL"
  case "$TUSD_EXT" in
    tar.gz)
      tar xzf "$CACHE_DIR/$TUSD_ASSET" -C "$TUSD_DIR" --strip-components=1
      ;;
    zip)
      # macOS unzip: -j junks paths, -d sets dest dir
      unzip -joq "$CACHE_DIR/$TUSD_ASSET" -d "$TUSD_DIR"
      ;;
  esac
  chmod +x "$TUSD_BIN"
fi

# sha256 helper that works on both platforms
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

say "Starting tusd $TUSD_VERSION on $TUSD_HOST:$TUSD_PORT"
"$TUSD_BIN" \
  -host "$TUSD_HOST" \
  -port "$TUSD_PORT" \
  -upload-dir "$UPLOAD_DIR" \
  -base-path /files/ \
  > "$WORK_DIR/tusd.log" 2>&1 &
TUSD_PID=$!

# Wait up to 5s for tusd to accept requests.
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "http://$TUSD_HOST:$TUSD_PORT/files/" 2>/dev/null \
     || curl -sS -o /dev/null -w '%{http_code}' "http://$TUSD_HOST:$TUSD_PORT/files/" 2>/dev/null \
        | grep -qE '^(2|4)[0-9]{2}$'; then
    break
  fi
  sleep 0.1
done

# Upload $fixture, locate it, download it back, and compare SHA-256s.
roundtrip() { # $1 = label, $2 = fixture path
  local label="$1" fixture="$2"
  local sum_src sum_dst url downloaded
  sum_src="$(sha256 "$fixture")"
  say "[$label] src sha256: $sum_src ($(wc -c < "$fixture") bytes)"

  say "[$label] Uploading via tusc.sh"
  ( cd "$REPO_ROOT" && bash ./tusc.sh -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -S -C )

  say "[$label] Locating uploaded URL"
  url="$(
    cd "$REPO_ROOT" \
      && bash ./tusc.sh -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -L -S -C \
         | awk '/^[[:space:]]*URL:[[:space:]]/ { sub(/^[[:space:]]*URL:[[:space:]]+/, ""); print; exit }'
  )"
  [[ -n "$url" && "$url" != "null" ]] || fail "[$label] could not locate uploaded URL"
  say "[$label] URL: $url"

  downloaded="$WORK_DIR/${label}.downloaded"
  say "[$label] Downloading via curl"
  curl -fsSL "$url" -o "$downloaded"

  sum_dst="$(sha256 "$downloaded")"
  say "[$label] dst sha256: $sum_dst"
  [[ "$sum_src" == "$sum_dst" ]] \
    || fail "[$label] checksum mismatch: src=$sum_src dst=$sum_dst"
  # Byte-exact comparison catches the rare hash collision and any
  # length/truncation surprises sha256 wouldn't flag.
  cmp -s "$fixture" "$downloaded" \
    || fail "[$label] bytes differ between source and downloaded copy"
  say "[$label] PASS"
}

# --- Binary fixture: 5 MiB of random bytes (covers chunked upload + NULs).
BIN_FIXTURE="$WORK_DIR/fixture.bin"
say "Generating 5 MiB binary fixture"
dd if=/dev/urandom of="$BIN_FIXTURE" bs=1024 count=5120 2>/dev/null
roundtrip binary "$BIN_FIXTURE"

# --- Text fixture: small ASCII + UTF-8 + blank/CRLF/trailing-newline mix.
TXT_FIXTURE="$WORK_DIR/fixture.txt"
say "Generating text fixture"
{
  printf 'tusc.sh end-to-end text roundtrip\n'
  printf '=================================\n\n'
  printf 'ASCII line with spaces and tabs:\there\tand\there\n'
  printf 'UTF-8: café — naïve — 日本語 — 🎉\n'
  printf 'Line with CRLF line ending\r\n'
  printf '\n'
  for i in $(seq 1 200); do
    printf 'line %03d: the quick brown fox jumps over the lazy dog\n' "$i"
  done
  printf 'no trailing newline'
} > "$TXT_FIXTURE"
roundtrip text "$TXT_FIXTURE"

say "All fixtures PASS"
