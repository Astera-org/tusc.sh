#!/usr/bin/env bash
#
# End-to-end test suite for tusc.sh.
# Works on macOS (stock /bin/bash 3.2) and Linux.
# Requires: curl, tar, awk, cmp, openssl, shasum (or sha256sum),
#           python3 (for the misbehaving-server stubs).
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
# Pidfile path — single file, lives in $WORK_DIR. Callers use
# `port=$(start_python_stub ...)` which runs the helper in a subshell;
# a STUB_PID variable assigned there would be lost to the parent. The
# pidfile crosses the subshell boundary cleanly.
STUB_PIDFILE="$WORK_DIR/stub.pid"
cleanup() {
  local rc=$? pid
  if [[ -n "$TUSD_PID" ]]; then
    kill -0 "$TUSD_PID" 2>/dev/null && kill "$TUSD_PID" 2>/dev/null && wait "$TUSD_PID" 2>/dev/null || true
  fi
  if [[ -f "$STUB_PIDFILE" ]]; then
    pid=$(cat "$STUB_PIDFILE" 2>/dev/null) || pid=""
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
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

say()  { printf '>>> %s\n' "$*"; }
fail() { printf '    FAIL: %s\n' "$*" >&2; return 1; }

# ---- tusd setup ------------------------------------------------------

if [[ ! -x "$TUSD_BIN" ]]; then
  say "Downloading tusd $TUSD_VERSION ($TUSD_OS/$TUSD_ARCH)"
  mkdir -p "$TUSD_DIR"
  curl -fsSLo "$CACHE_DIR/$TUSD_ASSET" "$TUSD_URL"
  case "$TUSD_EXT" in
    tar.gz) tar xzf "$CACHE_DIR/$TUSD_ASSET" -C "$TUSD_DIR" --strip-components=1 ;;
    zip)    unzip -joq "$CACHE_DIR/$TUSD_ASSET" -d "$TUSD_DIR" ;;
  esac
  chmod +x "$TUSD_BIN"
fi

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
  curl -sS -o /dev/null -w '%{http_code}' "http://$TUSD_HOST:$TUSD_PORT/files/" 2>/dev/null \
    | grep -qE '^(2|4)[0-9]{2}$' && break
  sleep 0.1
done

# ---- helpers ---------------------------------------------------------

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}
sha1_stdin() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  else shasum -a 1 | awk '{print $1}'; fi
}

# Compute the script's UPLOAD_KEY (sha256 of content:host:basepath:name).
upload_key_for() { # $1=file, $2=host (with port), $3=basepath, $4=name
  local key; key=$(sha256 "$1")
  printf '%s:%s:%s:%s' "$key" "$2" "$3" "$4" | sha256_stdin
}

# Seed tusc's loc cache with a known URL for (file, host, basepath, name).
# Writes to: <tdir>/loc.<upload-key>.<sha1-of-host+basepath>
seed_loc_cache() { # $1=tdir, $2=file, $3=host, $4=basepath, $5=name, $6=url
  local upload_key hostsha
  upload_key=$(upload_key_for "$2" "$3" "$4" "$5")
  hostsha=$(printf '%s' "$3$4" | sha1_stdin)
  printf %s "$6" > "$1/loc.$upload_key.$hostsha"
}

# Run tusc.sh from the repo root. Per-test TUSDIR isolates resume state.
tusc() { ( cd "$REPO_ROOT" && bash ./tusc.sh "$@" ); }

# Extract the URL line out of tusc.sh output.
extract_url() { awk '/^[[:space:]]*URL:[[:space:]]/ { sub(/^[[:space:]]*URL:[[:space:]]+/, ""); print; exit }'; }

# Launch a Python HTTP stub on a random port. The argument is the
# Python *body* of the handler (typically a class H definition);
# we wrap it with the boilerplate that picks up $PORT and serves
# until killed. Writes the PID to $STUB_PIDFILE (works across the
# command-substitution subshell that callers use), prints the port
# on stdout. Waits for the port to accept connections.
#
# Return codes:
#   0 — stub started, port is on stdout
#   1 — python3 not available (caller should "skip")
#   2 — python3 present, but the stub never accepted a connection
#       (caller should FAIL — this is a test-infra bug, not a skip).
#       A diagnostic is written to stderr before returning.
#
# Caller pattern (replaces the broken "skip on any failure"):
#   port=$(require_python_stub '...') || {
#     local rc=$?
#     [[ $rc -eq 1 ]] && { say "    skip: python3 not available"; return 0; }
#     return 1
#   }
start_python_stub() # $1 = python body
{
  command -v python3 >/dev/null 2>&1 || return 1
  # If a previous test left a stub running (e.g. it failed before
  # calling stop_python_stub), reap it so we don't leak Python
  # processes for the lifetime of the test suite.
  if [[ -f "$STUB_PIDFILE" ]]; then
    local prev; prev=$(cat "$STUB_PIDFILE" 2>/dev/null) || prev=""
    [[ -n "$prev" ]] && kill "$prev" 2>/dev/null && wait "$prev" 2>/dev/null || true
    rm -f "$STUB_PIDFILE"
  fi
  local port=$((40000 + RANDOM % 10000))
  local stub="$WORK_DIR/stub-$port.py"
  {
    printf 'import http.server, socketserver, sys, threading\n'
    printf 'PORT = int(sys.argv[1])\n'
    printf '%s\n' "$1"
    printf 'socketserver.TCPServer.allow_reuse_address = True\n'
    printf 'with socketserver.TCPServer(("127.0.0.1", PORT), H) as s: s.serve_forever()\n'
  } > "$stub"
  python3 "$stub" "$port" >/dev/null 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$STUB_PIDFILE"
  local _ ready=0
  for _ in $(seq 1 50); do
    if curl -sS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
    sleep 0.05
  done
  if [[ $ready -eq 0 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$STUB_PIDFILE"
    printf '    FAIL: python stub on port %d never accepted a connection\n' "$port" >&2
    return 2
  fi
  printf '%s\n' "$port"
}

# Thin wrapper around start_python_stub: handles the "python3 missing
# vs stub broke" decision so callers don't repeat the rc-branching.
# Returns:
#   0 — stub ready, port on stdout
#   2 — python3 missing (skip message printed; caller should `return 0`)
#   1 — stub failed to launch (FAIL diagnostic was on stderr from
#       start_python_stub; caller should `return 1`)
#
# Caller idiom — one short line that maps both failures correctly:
#   port=$(require_python_stub '...') || return $((2 - $?))
# (rc=1 -> caller returns 1 (FAIL); rc=2 -> caller returns 0 (skip-PASS))
require_python_stub() # $1 = python body
{
  local port rc
  port=$(start_python_stub "$1") && { printf '%s\n' "$port"; return 0; }
  rc=$?
  if [[ $rc -eq 1 ]]; then
    say "    skip: python3 not available"
    return 2
  fi
  return 1
}

# Stop the running Python stub via the pidfile (which crosses the
# command-substitution subshell boundary the helper runs in). Safe
# to call when no stub is running.
stop_python_stub()
{
  [[ -f "$STUB_PIDFILE" ]] || return 0
  local pid; pid=$(cat "$STUB_PIDFILE" 2>/dev/null) || pid=""
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$STUB_PIDFILE"
}

# ---- test framework --------------------------------------------------

PASS=0; FAILS=0; FAILED=()
run() {
  local name="$1"; shift
  say "▶ $name"
  if ( set +e; "$@"; ); then
    PASS=$((PASS+1))
    printf '    ✓ PASS\n'
  else
    FAILS=$((FAILS+1))
    FAILED+=("$name")
    printf '    ✗ FAIL\n'
  fi
}

# ---- test cases ------------------------------------------------------

# Upload <fixture>, locate, download, compare sha256 + bytes.
roundtrip_helper() { # $1 = label, $2 = fixture
  local label="$1" fixture="$2"
  local tdir="$WORK_DIR/$label-cache"
  local sum_src sum_dst url downloaded
  sum_src="$(sha256 "$fixture")"

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -C >/dev/null
  url="$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -L -C | extract_url)"
  [[ -n "$url" && "$url" != "null" ]] || fail "could not locate uploaded URL"

  downloaded="$WORK_DIR/$label.downloaded"
  curl -fsSL "$url" -o "$downloaded"
  sum_dst="$(sha256 "$downloaded")"
  [[ "$sum_src" == "$sum_dst" ]] || fail "sha256 mismatch: src=$sum_src dst=$sum_dst"
  cmp -s "$fixture" "$downloaded" || fail "bytes differ src vs downloaded"
}

test_binary_roundtrip() {
  local f="$WORK_DIR/bin.bin"
  dd if=/dev/urandom of="$f" bs=1024 count=5120 2>/dev/null
  roundtrip_helper binary "$f"
}

test_text_roundtrip() {
  local f="$WORK_DIR/text.txt"
  {
    printf 'tusc.sh end-to-end text roundtrip\n=================================\n\n'
    printf 'ASCII line with spaces and tabs:\there\tand\there\n'
    printf 'UTF-8: café — naïve — 日本語 — 🎉\n'
    printf 'Line with CRLF line ending\r\n\n'
    for i in $(seq 1 200); do printf 'line %03d: the quick brown fox\n' "$i"; done
    printf 'no trailing newline'
  } > "$f"
  roundtrip_helper text "$f"
}

test_cache_hit_message() {
  local f="$WORK_DIR/cache.bin"; local tdir="$WORK_DIR/cache-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=64 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C)
  grep -q "Already uploaded" <<< "$out" || fail "expected 'Already uploaded' on cache hit; got: $out"
}

test_restart_replaces_upload() {
  local f="$WORK_DIR/restart.bin"; local tdir="$WORK_DIR/restart-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=64 2>/dev/null
  local u1 u2
  u1=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C | extract_url)
  u2=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C --restart | extract_url)
  [[ -n "$u1" && -n "$u2" ]] || fail "missing URL on one of the runs: u1=$u1 u2=$u2"
  [[ "$u1" != "$u2" ]] || fail "--restart did not create a fresh upload (same URL: $u1)"
}

test_done_marker_trusts_local_state_over_server_404() {
  # Once we've successfully uploaded a file, the local "done" marker
  # is authoritative: a later run reports "Already uploaded" without
  # HEAD'ing the cached URL — many TUS servers move/rename the upload
  # after completion, so that URL would 404 and the script can't
  # distinguish "server moved it" from "server lost it". --restart is
  # the explicit override for "I know the server actually lost it".
  local f="$WORK_DIR/stale.bin"; local tdir="$WORK_DIR/stale-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=64 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null
  # Wipe tusd's upload dir to simulate a server that purged or moved
  # the upload after the fact.
  rm -rf "$UPLOAD_DIR"; mkdir -p "$UPLOAD_DIR"

  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C)
  grep -q "Already uploaded" <<< "$out" \
    || { fail "expected 'Already uploaded' from done-marker; got: $out"; return 1; }

  # --restart bypasses the marker and actually re-uploads.
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C --restart)
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "expected fresh upload under --restart; got: $out"; return 1; }
}

test_dir_upload_preserves_paths() {
  # The source directory's basename must become the first path segment
  # of every upload's filename — i.e. the directory itself shows up at
  # the destination rather than being flattened into the upload root.
  local root="$WORK_DIR/dir-src"; local tdir="$WORK_DIR/dir-cache"
  mkdir -p "$root/a/b" "$root/c"
  echo aaa > "$root/top.txt"
  echo bbb > "$root/a/b/nested.txt"
  echo ccc > "$root/c/cc.bin"

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C >/dev/null \
    || fail "tusc -d failed"

  # tusd v2 stores Upload-Metadata in <uploadid>.info next to the file.
  # Every uploaded file must show "dir-src/<rel-path>" in its .info.
  local expected_names=(dir-src/top.txt dir-src/a/b/nested.txt dir-src/c/cc.bin)
  local n found
  for n in "${expected_names[@]}"; do
    found=0
    for info in "$UPLOAD_DIR"/*.info; do
      grep -q "\"filename\":\"$n\"" "$info" && { found=1; break; }
    done
    [[ $found -eq 1 ]] || fail "no .info has filename=$n"
  done
  # Sanity: nothing should be uploaded with a leading-segment-stripped
  # name (e.g. bare "top.txt" without the dir-src/ prefix).
  for info in "$UPLOAD_DIR"/*.info; do
    grep -q '"filename":"top.txt"' "$info" && fail "found unprefixed top.txt"
  done
  return 0
}

test_zero_byte_file() {
  # 0-byte files: the POST creates the upload at its terminal state
  # (Upload-Length: 0). The script must NOT send a follow-up empty
  # PATCH — some servers reject it as 404 ERR_UPLOAD_NOT_FOUND.
  local f="$WORK_DIR/empty.bin"; local tdir="$WORK_DIR/empty-cache"
  : > "$f"
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C) || {
    fail "0-byte upload exited non-zero"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" || {
    fail "0-byte upload didn't print success: $out"; return 1; }
  local url; url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -C | extract_url)
  [[ -n "$url" ]] || { fail "could not locate 0-byte upload"; return 1; }
  curl -fsSL "$url" -o "$WORK_DIR/empty.dl"
  local dl_size; dl_size=$(wc -c < "$WORK_DIR/empty.dl" | tr -d ' ')
  [[ "$dl_size" == 0 ]] || { fail "downloaded empty upload was $dl_size bytes, expected 0"; return 1; }
}

test_resume_from_readonly_source_dir() {
  # Resume from a file whose containing directory is read-only must
  # not try to write a .part next to the source. The script stages
  # the partial slice under $TUSDIR instead.
  local rodir="$WORK_DIR/ro"; local tdir="$WORK_DIR/ro-cache"
  mkdir -p "$rodir" "$tdir"
  dd if=/dev/urandom of="$rodir/big.bin" bs=1024 count=1024 2>/dev/null   # 1 MiB
  chmod 555 "$rodir"

  # Seed a partial upload (256 KiB out of 1 MiB) and prime tusc's cache.
  local size; size=$(wc -c < "$rodir/big.bin" | tr -d ' ')
  local name_b64; name_b64=$(printf %s "big.bin" | base64 | tr -d '\n')
  local hdr; hdr=$(mktemp -t ro-hdr.XXXXXX)
  curl -fsSLD "$hdr" \
    -H "Tus-Resumable: 1.0.0" \
    -H "Upload-Length: $size" \
    -H "Upload-Metadata: filename $name_b64" \
    -X POST "http://$TUSD_HOST:$TUSD_PORT/files/" >/dev/null
  local loc; loc=$(awk -F': ' 'tolower($1)=="location" {sub(/\r$/,"",$2); print $2; exit}' "$hdr")
  rm -f "$hdr"
  dd if="$rodir/big.bin" bs=1024 count=256 2>/dev/null > "$WORK_DIR/ro-chunk"
  local sum; sum=$(openssl dgst -sha256 -binary "$WORK_DIR/ro-chunk" | base64 | tr -d '\n')
  curl -fsSL \
    -H "Tus-Resumable: 1.0.0" \
    -H "Content-Type: application/offset+octet-stream" \
    -H "Upload-Offset: 0" \
    -H "Upload-Checksum: sha256 $sum" \
    --data-binary "@$WORK_DIR/ro-chunk" -X PATCH "$loc" >/dev/null

  seed_loc_cache "$tdir" "$rodir/big.bin" "$TUSD_HOST:$TUSD_PORT" "/files/" "big.bin" "$loc"

  local out rc
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$rodir/big.bin" -a sha256 -C 2>&1) && rc=0 || rc=$?
  chmod 755 "$rodir"   # restore for cleanup
  [[ $rc -eq 0 ]] || { fail "expected resume to succeed on read-only source dir; rc=$rc out=$out"; return 1; }
  grep -q "↻ Resuming at byte 262144" <<< "$out" \
    || { fail "expected resume message — fresh upload happened instead: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" || { fail "no success message: $out"; return 1; }
  [[ ! -e "$rodir/big.bin.part" ]] || { fail ".part leaked next to source"; return 1; }
}

test_path_with_spaces() {
  # File path with a space exercises every quoting hazard in the
  # cleanup trap, metadata building, and curl invocation.
  local f="$WORK_DIR/has space.bin"; local tdir="$WORK_DIR/space-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=32 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null \
    || fail "upload failed for path with spaces"
  local url
  url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -C | extract_url)
  [[ -n "$url" ]] || fail "could not locate upload of spaced-path file"
  local got="$WORK_DIR/got.bin"
  curl -fsSL "$url" -o "$got"
  cmp -s "$f" "$got" || fail "spaced-path file bytes differ"
}

test_identical_content_different_names() {
  # Two files with identical bytes at different upload paths must
  # produce distinct uploads (Upload-Key is namespaced by destination
  # name so content-deduping servers don't collide them).
  local root="$WORK_DIR/dupes"; local tdir="$WORK_DIR/dupes-cache"
  mkdir -p "$root/a" "$root/b"
  printf 'identical 39 bytes of fixture content..' > "$root/a/same.txt"
  printf 'identical 39 bytes of fixture content..' > "$root/b/same.txt"

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C >/dev/null \
    || fail "tusc -d failed on duplicate-content batch"

  # Both relpaths must be present in the upload-dir's .info files —
  # i.e. each got its own POST and its own PATCH succeeded.
  local n found
  for n in dupes/a/same.txt dupes/b/same.txt; do
    found=0
    for info in "$UPLOAD_DIR"/*.info; do
      grep -q "\"filename\":\"$n\"" "$info" && { found=1; break; }
    done
    [[ $found -eq 1 ]] || fail "duplicate-content file $n was not uploaded as its own object"
  done
}

test_name_override() {
  local f="$WORK_DIR/named.bin"; local tdir="$WORK_DIR/name-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=16 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -N "deep/path/renamed.bin" -a sha256 -C >/dev/null
  local found=0
  for info in "$UPLOAD_DIR"/*.info; do
    grep -q '"filename":"deep/path/renamed.bin"' "$info" && { found=1; break; }
  done
  [[ $found -eq 1 ]] || fail "Upload-Metadata.filename did not honor --name override"
}

test_dir_rerun_skips_completed_files() {
  # The user-reported scenario: re-running `--dir` against the same
  # source must short-circuit already-uploaded files via the done
  # marker. Without it, servers that move/rename completed uploads
  # would 404 every cached URL and the script would re-upload the
  # whole tree from scratch.
  local root="$WORK_DIR/rerun"; local tdir="$WORK_DIR/rerun-cache"
  mkdir -p "$root"
  printf 'a' > "$root/a.txt"
  printf 'b' > "$root/b.txt"

  # Run 1: fresh batch.
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C >/dev/null \
    || { fail "first dir upload failed"; return 1; }

  # Simulate the server moving the uploads away (purge upload-dir).
  rm -rf "$UPLOAD_DIR"; mkdir -p "$UPLOAD_DIR"

  # Run 2: every file should short-circuit with "Already uploaded";
  # no PATCH should hit the server.
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C)
  local already
  already=$(grep -c "Already uploaded" <<< "$out")
  [[ "$already" == 2 ]] \
    || { fail "expected 2 'Already uploaded' lines on re-run; got $already in: $out"; return 1; }
  local fresh
  fresh=$(grep -c "✔ Uploaded successfully" <<< "$out")
  [[ "$fresh" == 0 ]] \
    || { fail "re-run uploaded $fresh file(s) again; expected 0. out: $out"; return 1; }
  # And tusd's upload-dir is still empty — no PATCHes landed.
  local landed; landed=$(find "$UPLOAD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  [[ "$landed" == 0 ]] \
    || { fail "expected no server-side uploads on re-run; saw $landed file(s)"; return 1; }
}

test_dir_per_file_success_and_cleanup() {
  # Dir mode prints "Uploaded successfully!" + URL per file (bash
  # doesn't inherit the EXIT trap into a subshell, so reporting is
  # explicit). No part.* tempfiles in $TUSDIR after a clean batch.
  local root="$WORK_DIR/perfile"; local tdir="$WORK_DIR/perfile-cache"
  mkdir -p "$root/a"
  echo aaa > "$root/x.txt"
  echo bbb > "$root/a/y.txt"
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C) \
    || { fail "dir upload failed: $out"; return 1; }
  local upcount
  upcount=$(grep -c "Uploaded successfully" <<< "$out")
  [[ "$upcount" == 2 ]] \
    || { fail "expected 2 per-file 'Uploaded successfully' lines, got $upcount in: $out"; return 1; }
  local urlcount
  urlcount=$(grep -c "^URL: " <<< "$out")
  [[ "$urlcount" == 2 ]] \
    || { fail "expected 2 per-file URL lines, got $urlcount in: $out"; return 1; }
  # No part.* leftovers in cache.
  local leaks
  leaks=$(find "$tdir" -name 'part.*' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$leaks" == 0 ]] || { fail "part.* tempfile(s) leaked: $leaks"; return 1; }
}

test_dir_set_e_honored_inside_subshell() {
  # Dir mode must not use `( cmd ) || handler` (that disables set -e
  # inside the subshell). Point a child at an unreachable port and
  # assert it exits non-zero with a "Request failed" — no fall-through
  # to a fake success.
  local root="$WORK_DIR/seteset"; local tdir="$WORK_DIR/seteset-cache"
  mkdir -p "$root"
  echo aaa > "$root/x.txt"
  # 127.0.0.1:1 is reserved/refused → ECONNREFUSED on POST.
  local out
  out=$(TUSDIR="$tdir" tusc -H 127.0.0.1:1 -d -f "$root" -a sha256 -C 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { fail "dir upload to unreachable port unexpectedly succeeded; out=$out"; return 1; }
  grep -q "Request failed" <<< "$out" \
    || { fail "expected 'Request failed' from child; got: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    && { fail "must not print 'Uploaded successfully' when child failed: $out"; return 1; }
  return 0
}

test_creds_file_requires_both_user_and_pass() {
  # A creds file that sets only PASS must fail loudly; we must not
  # silently fall back to the shell's ambient $USER.
  local cf="$WORK_DIR/half-creds.sh"
  echo 'PASS="secret"' > "$cf"
  local out rc
  out=$(tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$WORK_DIR/cache-cache" -c "$cf" -a sha256 -C 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { fail "expected non-zero exit for half-populated creds file; out=$out"; return 1; }
  grep -q "must set both USER and PASS" <<< "$out" \
    || { fail "expected complaint about missing USER; got: $out"; return 1; }
}

test_checksum_cache_invalidates_on_size_change() {
  # Rewrite a file with mtime preserved but different size: cache key
  # must include size so the new bytes get re-hashed.
  local f="$WORK_DIR/cache-size.bin"; local tdir="$WORK_DIR/cache-size-cache"
  mkdir -p "$tdir"
  printf 'AAAA' > "$f"
  local mt; mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null
  # Rewrite with different content + size; restore the original mtime
  # (some editors do this; `cp -p`, `tar -p`, `touch -r` all preserve).
  printf 'BBBBBBBB' > "$f"
  if stat -f %m "$f" >/dev/null 2>&1; then
    touch -t "$(date -r "$mt" +%Y%m%d%H%M.%S)" "$f"
  else
    touch -d "@$mt" "$f"
  fi
  # Now re-run. If the cache short-circuited and reused the stale
  # digest, this run would post under the old upload (wrong KEY ->
  # wrong UPLOAD_KEY -> wrong server-side identity). With the fix, the
  # size change invalidates the entry and a fresh checksum is taken.
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "second upload failed: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "expected a fresh successful upload after content change; got: $out"; return 1; }
  # And the new upload must reflect the new size on the server.
  local url; url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -C | extract_url)
  [[ -n "$url" ]] || { fail "could not locate the second upload"; return 1; }
  curl -fsSL "$url" -o "$WORK_DIR/cache-size.dl"
  cmp -s "$f" "$WORK_DIR/cache-size.dl" \
    || { fail "downloaded content didn't match the new bytes (stale-cache hit)"; return 1; }
}

test_checksum_cache_invalidates_on_subsecond_rewrite() {
  # Two rewrites within the same wall-second, same size, different
  # bytes. Nanosecond-precision mtime in the cache key catches this;
  # second-resolution mtime alone does not.
  command -v openssl >/dev/null 2>&1 || { say "    skip: openssl needed"; return 0; }
  local f="$WORK_DIR/subsec.bin"; local tdir="$WORK_DIR/subsec-cache"
  mkdir -p "$tdir"
  # Same 16-byte size, different content.
  printf 'AAAAAAAAAAAAAAAA' > "$f"
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null
  # Rewrite immediately; on a fast filesystem this lands in the same
  # wall-second. Even if it doesn't, nanoseconds will differ.
  printf 'BBBBBBBBBBBBBBBB' > "$f"
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "second upload failed: $out"; return 1; }
  local url
  url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -C | extract_url)
  curl -fsSL "$url" -o "$WORK_DIR/subsec.dl"
  cmp -s "$f" "$WORK_DIR/subsec.dl" \
    || { fail "downloaded bytes didn't match the new content (stale-cache hit)"; return 1; }
}

test_tusc_nocache_forces_rehash() {
  # TUSC_NOCACHE=1 must bypass the checksum cache regardless of cache state.
  local f="$WORK_DIR/nocache.bin"; local tdir="$WORK_DIR/nocache-cache"
  printf 'hello' > "$f"
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C >/dev/null
  # With TUSC_NOCACHE the DEBUG trace must show the hashing step
  # ("> checksum sha256 ..."), which we suppress on cache hits.
  local out
  out=$(TUSDIR="$tdir" TUSC_NOCACHE=1 DEBUG=1 tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "TUSC_NOCACHE run failed: $out"; return 1; }
  grep -q "^> checksum sha256" <<< "$out" \
    || { fail "expected '> checksum sha256' in DEBUG trace under TUSC_NOCACHE=1; got: $out"; return 1; }
}

test_restart_sends_fresh_upload_key() {
  # --restart must send a different Upload-Key on POST (otherwise a
  # content-deduping server would hand back the old upload). Inspect
  # DEBUG traces for the normal vs restart POSTs and compare keys.
  local f="$WORK_DIR/restartkey.bin"; local tdir="$WORK_DIR/restartkey-cache"
  printf 'restartkey-content' > "$f"
  local out1 out2 k1 k2
  out1=$(TUSDIR="$tdir" DEBUG=1 tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "first upload failed: $out1"; return 1; }
  out2=$(TUSDIR="$tdir" DEBUG=1 tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C --restart 2>&1) \
    || { fail "restart upload failed: $out2"; return 1; }
  # Extract the Upload-Key value from each POST trace (single line
  # containing both -X POST and Upload-Key:\ <hex>).
  k1=$(grep -- "-X POST" <<< "$out1" | grep -oE 'Upload-Key:[\\ ]*[a-f0-9-]+' | head -1)
  k2=$(grep -- "-X POST" <<< "$out2" | grep -oE 'Upload-Key:[\\ ]*[a-f0-9-]+' | head -1)
  [[ -n "$k1" && -n "$k2" ]] || { fail "could not find Upload-Key in POST trace; out1=$out1 out2=$out2"; return 1; }
  [[ "$k1" != "$k2" ]] || { fail "--restart used the same Upload-Key on POST ($k1)"; return 1; }
}

test_locate_requires_host() {
  # --locate without --host has nothing to look up (cache is keyed by
  # host+base-path). The script must reject it instead of pretending
  # to print an empty URL.
  local f="$WORK_DIR/loc-req.bin"
  printf x > "$f"
  local out rc
  out=$(tusc -L -f "$f" -a sha256 -C 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { fail "--locate without --host unexpectedly succeeded: $out"; return 1; }
  grep -q "host required" <<< "$out" \
    || { fail "expected --host required error; got: $out"; return 1; }
}

test_upload_key_includes_destination() {
  # UPLOAD_KEY must hash content + host + base-path + name. Assert the
  # key changes when only the host changes and when only the base-path
  # changes.
  local f="$WORK_DIR/bp.bin"
  printf 'shared bytes' > "$f"
  local same other_host other_base
  same=$(upload_key_for       "$f" "h1" "/files/" "bp.bin")
  other_host=$(upload_key_for "$f" "h2" "/files/" "bp.bin")
  other_base=$(upload_key_for "$f" "h1" "/other/" "bp.bin")
  [[ "$same" != "$other_host" ]] || { fail "UPLOAD_KEY collided across hosts"; return 1; }
  [[ "$same" != "$other_base" ]] || { fail "UPLOAD_KEY collided across base-paths"; return 1; }
}

test_dir_manifest_cleaned_on_interrupt() {
  # Manifest tempfile must be cleaned up by the EXIT trap even when
  # the upload loop is interrupted. Force an early exit by pointing
  # at an unreachable host and assert no manifest.* remains.
  local root="$WORK_DIR/manif"; local tdir="$WORK_DIR/manif-cache"
  mkdir -p "$root"
  echo aaa > "$root/x.txt"
  TUSDIR="$tdir" tusc -H 127.0.0.1:1 -d -f "$root" -a sha256 -C >/dev/null 2>&1 || true
  local leaks
  leaks=$(find "$tdir" -name 'manifest.*' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$leaks" == 0 ]] || { fail "manifest.* leaked after interrupted dir upload ($leaks file(s))"; return 1; }
}

test_invalid_algo_rejected() {
  # Algorithm whitelist: only sha1/sha224/sha256/sha384/sha512.
  local f="$WORK_DIR/algo.bin"
  printf x > "$f"
  local out rc
  out=$(TUSDIR="$WORK_DIR/algo-cache" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha999 -C 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { fail "sha999 should be rejected; out=$out"; return 1; }
  grep -q "'sha999' not supported" <<< "$out" \
    || { fail "expected explicit rejection message for sha999; got: $out"; return 1; }
}

test_dir_forwards_curl_passthrough() {
  # Curl passthrough args (everything after `--`) must reach the
  # per-file curl invocation in dir mode, not just single-file mode.
  local root="$WORK_DIR/dirfwd"; local tdir="$WORK_DIR/dirfwd-cache"
  mkdir -p "$root"
  echo aaa > "$root/x.txt"
  local out
  out=$(TUSDIR="$tdir" DEBUG=1 tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -C \
        -- -H "X-Tusc-Passthrough: yes" 2>&1) \
    || { fail "dir upload failed: $out"; return 1; }
  # Both the POST and the PATCH should include the passthrough header.
  # The DEBUG trace renders argv via printf %q, which backslash-escapes
  # the space in "X-Tusc-Passthrough: yes" — so match on the name only.
  local post_seen patch_seen
  post_seen=$(grep -c -- "X-Tusc-Passthrough.*-X POST" <<< "$out")
  patch_seen=$(grep -c -- "X-Tusc-Passthrough.*--request PATCH" <<< "$out")
  [[ "$post_seen" -ge 1 ]] || { fail "passthrough header missing from POST in: $out"; return 1; }
  [[ "$patch_seen" -ge 1 ]] || { fail "passthrough header missing from PATCH in: $out"; return 1; }
}

test_retries_recover_from_transient_patch_failure() {
  # First PATCH attempt is killed by the server (TCP RST mid-stream
  # via shutdown(socket, SHUT_WR)); --retries 1 should re-HEAD, learn
  # the server saved 0 bytes, re-slice, and try again — and succeed.
  local port
  port=$(require_python_stub '
state = {"patches": 0}
state_lock = threading.Lock()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "http://127.0.0.1:%d/files/RETRY-ID" % PORT)
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", "0")
        self.send_header("Upload-Length", "16")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        with state_lock:
            state["patches"] += 1; n = state["patches"]
        if n == 1:
            try: self.rfile.read(4)
            except Exception: pass
            try: self.connection.shutdown(1); self.connection.close()
            except Exception: pass
            return
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/retry.bin"; local tdir="$WORK_DIR/retry-cache"
  printf 'sixteen-bytes!ok' > "$f"   # 16 bytes — matches stub's Upload-Length
  local out rc
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C --retries 1 2>&1) && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -eq 0 ]] || { fail "retry run failed: $out"; return 1; }
  grep -q "↻ chunk 1 PATCH failed (transient), retry 1/1" <<< "$out" \
    || { fail "expected retry-1 banner; got: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "retry didn't finish the upload: $out"; return 1; }
}

test_retries_do_not_mask_4xx() {
  # 4xx responses are not transient. --retries 5 must NOT retry on
  # 404 — it would mask configuration / auth bugs.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "http://127.0.0.1:%d/files/X" % PORT)
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", "0")
        self.send_header("Upload-Length", "5")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        try: self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        except Exception: pass
        self.send_response(403)
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/retry4xx.bin"; local tdir="$WORK_DIR/retry4xx-cache"
  printf 'hello' > "$f"
  local out rc
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C --retries 5 2>&1) && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -ne 0 ]] || { fail "expected non-zero exit on 403; got 0 in: $out"; return 1; }
  grep -q "HTTP 403" <<< "$out" \
    || { fail "expected HTTP 403 in error; got: $out"; return 1; }
  if grep -q "PATCH failed (transient), retry" <<< "$out"; then
    fail "retried on 403; must only retry transient failures: $out"
    return 1
  fi
}

test_chunked_patch_uploads_in_multiple_patches() {
  # With --chunk-size smaller than the file, the script must send
  # multiple PATCH requests instead of one. Count PATCHes via a stub.
  local port
  port=$(require_python_stub '
state = {"patches": 0, "offset": 0}
lk = threading.Lock()
SIZE = 200 * 1024   # 200 KiB
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201); self.send_header("Tus-Resumable","1.0.0")
        self.send_header("Location","http://127.0.0.1:%d/files/CHUNKED"%PORT)
        self.send_header("Content-Length","0"); self.end_headers()
    def do_HEAD(self):
        self.send_response(200); self.send_header("Tus-Resumable","1.0.0")
        self.send_header("Upload-Offset",str(state["offset"]))
        self.send_header("Upload-Length",str(SIZE))
        self.send_header("Content-Length","0"); self.end_headers()
    def do_PATCH(self):
        bl=int(self.headers.get("Content-Length","0"))
        if bl: self.rfile.read(bl)
        with lk:
            state["patches"] += 1; state["offset"] += bl; new_off = state["offset"]
        self.send_response(204); self.send_header("Tus-Resumable","1.0.0")
        self.send_header("Upload-Offset",str(new_off))
        self.send_header("Content-Length","0"); self.end_headers()
    def log_message(self,*a,**k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/chunked.bin"; local tdir="$WORK_DIR/chunked-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=200 2>/dev/null   # 200 KiB
  local out
  out=$(TUSDIR="$tdir" DEBUG=1 tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C \
        --chunk-size 64K 2>&1) \
    || { stop_python_stub; fail "chunked upload failed: $out"; return 1; }
  stop_python_stub

  # 200 KiB / 64 KiB -> 4 chunks (64 + 64 + 64 + 8).
  local patches; patches=$(grep -c "^> curl .*--request PATCH" <<< "$out")
  [[ "$patches" == 4 ]] \
    || { fail "expected 4 PATCH requests for 200K / 64K chunks; got $patches in: $out"; return 1; }
  grep -q "chunk 1/4" <<< "$out" \
    || { fail "expected chunk progress banner; got: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "chunked upload did not print success: $out"; return 1; }
}

test_chunk_size_parser_accepts_suffixes() {
  # --chunk-size accepts plain bytes, K, M, G suffixes (binary).
  local f="$WORK_DIR/cs.bin"
  printf x > "$f"
  # Round-trip a few sizes via a tiny tusd upload; if any value is
  # rejected the run exits non-zero.
  for sz in 1024 64K 1M 1G; do
    local tdir="$WORK_DIR/cs-$sz-cache"
    TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C \
      --chunk-size "$sz" >/dev/null \
      || { fail "--chunk-size $sz was rejected"; return 1; }
  done
  # Bad sizes must error out. '0' and '0K' are positive-size violations
  # (would divide-by-zero in the chunk-count math); 'garbage' is a
  # parse failure. Both should fail before reaching the upload loop.
  local rc bad
  for bad in garbage 0 0K; do
    TUSDIR="$WORK_DIR/cs-bad-$bad-cache" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C \
      --chunk-size "$bad" >/dev/null 2>&1 && rc=0 || rc=$?
    [[ $rc -ne 0 ]] || { fail "--chunk-size '$bad' should be rejected"; return 1; }
  done
}

test_retries_inf_is_accepted() {
  # 'inf' is the documented sentinel for unlimited retries. Just
  # verify it parses (single-PATCH upload completes without ever
  # tripping the retry path).
  local f="$WORK_DIR/inf.bin"; local tdir="$WORK_DIR/inf-cache"
  printf hello > "$f"
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C \
    --retries inf >/dev/null \
    || { fail "--retries inf was rejected"; return 1; }
}

test_retries_invalid_value_rejected() {
  # Anything other than a non-negative integer or 'inf'/'infinite' must
  # fail loudly. Silent fall-through to 0 retries would mask CLI typos.
  local f="$WORK_DIR/badretries.bin"; local tdir="$WORK_DIR/badretries-cache"
  printf x > "$f"
  local rc out bad
  for bad in garbage 3x -1 " "; do
    out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C \
          --retries "$bad" 2>&1) && rc=0 || rc=$?
    [[ $rc -ne 0 ]] || { fail "--retries '$bad' should be rejected; out: $out"; return 1; }
    grep -q -- "--retries" <<< "$out" \
      || { fail "expected --retries error mention for '$bad'; got: $out"; return 1; }
  done
}

test_user_w_does_not_break_effective_url_marker() {
  # A user-supplied `-- -w ...` must not override the internal -w that
  # carries %{url_effective}. Our -w goes after CURLARGS so curl picks
  # ours as the last one. Exercise via the path-relative resolution
  # path (which needs EFFECTIVE_URL) and a benign passthrough -w.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "uploads/W-ID")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/relw.bin"; local tdir="$WORK_DIR/relw-cache"
  printf 'with-user-w' > "$f"
  # Pass a user -w that would, if it won precedence, replace our
  # marker output and leave EFFECTIVE_URL empty.
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C \
    -- -w '%{http_code}\n' >/dev/null 2>&1 || true
  stop_python_stub

  local cached; cached=$(cat "$tdir"/loc.* 2>/dev/null | head -1)
  [[ "$cached" == "http://127.0.0.1:$port/files/uploads/W-ID" ]] \
    || { fail "user -- -w broke EFFECTIVE_URL resolution; cached: $cached"; return 1; }
}

test_path_relative_location_is_resolved() {
  # Path-relative Location ("uploads/123", no leading slash) must
  # resolve against the directory of the POST URL.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "uploads/REL-ID")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/pathrel.bin"; local tdir="$WORK_DIR/pathrel-cache"
  printf 'path-relative-loc' > "$f"
  local rc
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C >/dev/null 2>&1 && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -eq 0 ]] || { fail "upload with path-relative Location failed: rc=$rc"; return 1; }
  local cached; cached=$(cat "$tdir"/loc.* 2>/dev/null | head -1)
  [[ "$cached" == "http://127.0.0.1:$port/files/uploads/REL-ID" ]] \
    || { fail "expected http://127.0.0.1:$port/files/uploads/REL-ID; got: $cached"; return 1; }
}

test_relative_location_is_resolved() {
  # Per the TUS spec the server may return Location relative to HOST.
  # The script must resolve "/path/<id>" against the host's
  # scheme+authority before caching / PATCHing.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "/files/REL-UPLOAD-ID")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/rel.bin"; local tdir="$WORK_DIR/rel-cache"
  printf 'relative-loc' > "$f"
  local out
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C 2>&1) && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -eq 0 ]] || { fail "upload against relative-Location server failed: $out"; return 1; }
  local cached; cached=$(cat "$tdir"/loc.* 2>/dev/null | head -1)
  [[ "$cached" == "http://127.0.0.1:$port/files/REL-UPLOAD-ID" ]] \
    || { fail "expected absolute URL in cache; got: $cached"; return 1; }
}

test_post_with_no_location_errors() {
  # A 2xx POST that omits Location is unusable — no URL to PATCH or
  # cache. Must fail loudly instead of "succeeding" with an empty URL.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/noloc.bin"; local tdir="$WORK_DIR/noloc-cache"
  printf 'no-loc' > "$f"
  local out rc
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C 2>&1) && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -ne 0 ]] || { fail "expected non-zero exit when POST returns no Location; got 0, out=$out"; return 1; }
  grep -q "no Location header" <<< "$out" \
    || { fail "expected explicit no-Location-header error; got: $out"; return 1; }
}

test_debug_drops_curl_v_when_auth_present() {
  # `curl -v` prints the Authorization header. Under DEBUG=1 with
  # creds the script must omit -v unless TUSC_DEBUG_UNSAFE=1 is also
  # set. Detect via the absence of "* Connected to" (a curl -v line)
  # in the transcript when creds are present.
  local f="$WORK_DIR/vauth.bin"; local tdir="$WORK_DIR/vauth-cache"
  printf 'hi' > "$f"
  local out
  out=$(TUSDIR="$tdir" TUSC_USER=alice TUSC_PASS=secret DEBUG=1 \
        tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "auth upload failed: $out"; return 1; }
  # No curl-verbose lines (those start with "* ", e.g. "* Connected to ...").
  if grep -q "^\* " <<< "$out"; then
    fail "curl -v transcript present in DEBUG output despite HAS_AUTH; out: $out"
    return 1
  fi
  # The synthetic '> curl ...' line is still there (our own argv trace).
  grep -q "^> curl " <<< "$out" \
    || { fail "expected synthetic '> curl' debug line; got: $out"; return 1; }
  # TUSC_DEBUG_UNSAFE=1 must re-enable -v.
  out=$(TUSDIR="${tdir}2" TUSC_USER=alice TUSC_PASS=secret TUSC_DEBUG_UNSAFE=1 DEBUG=1 \
        tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "TUSC_DEBUG_UNSAFE upload failed: $out"; return 1; }
  grep -q "^\* " <<< "$out" \
    || { fail "TUSC_DEBUG_UNSAFE=1 should re-enable curl -v; got: $out"; return 1; }
}

test_relative_location_after_redirect_uses_effective_url() {
  # POST /files/ -> 307 /v2/files/ ; final 201 returns
  # Location: uploads/REL-ID (path-relative, no leading slash).
  # Resolution base must be the post-redirect /v2/files/, not the
  # original /files/, so the cached URL contains /v2/files/uploads/.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/files/":
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:%d/v2/files/" % PORT)
            self.send_header("Content-Length", "0"); self.end_headers()
            return
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "uploads/REL-ID")
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/redir-rel.bin"; local tdir="$WORK_DIR/redir-rel-cache"
  printf 'redir-relative' > "$f"
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C >/dev/null 2>&1 || true
  stop_python_stub

  local cached; cached=$(cat "$tdir"/loc.* 2>/dev/null | head -1)
  [[ "$cached" == "http://127.0.0.1:$port/v2/files/uploads/REL-ID" ]] \
    || { fail "expected post-redirect resolution; got: $cached"; return 1; }
}

test_header_returns_final_response_after_redirect() {
  # When the POST is redirected before the final 201, header() must
  # return the final response's Location, not the redirect's.
  local port
  port=$(require_python_stub '
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/files/":
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:%d/v2/files/" % PORT)
            self.send_header("Content-Length", "0"); self.end_headers()
            return
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", "http://127.0.0.1:%d/v2/files/REAL-UPLOAD-ID" % PORT)
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_PATCH(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        if body_len: self.rfile.read(body_len)
        self.send_response(204)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Upload-Offset", str(body_len))
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
') || return $((2 - $?))

  local f="$WORK_DIR/redir.bin"; local tdir="$WORK_DIR/redir-cache"
  printf 'redir-payload' > "$f"
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$f" -a sha256 -C >/dev/null 2>&1 || true
  stop_python_stub

  # The cache must hold the FINAL URL, not the redirect target.
  local cached
  cached=$(cat "$tdir"/loc.* 2>/dev/null | head -1)
  [[ "$cached" == *"REAL-UPLOAD-ID"* ]] \
    || { fail "cached URL should be the final upload URL; got: $cached"; return 1; }
}

test_debug_masks_password_with_metacharacters() {
  # DEBUG must mask passwords containing shell metacharacters
  # (space, $, "), not just plain ones.
  local f="$WORK_DIR/maskmeta.bin"; local tdir="$WORK_DIR/maskmeta-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=4 2>/dev/null
  local pw='p w$x"y'   # space + $ + " — all need shell escaping
  local out
  out=$(TUSDIR="$tdir" TUSC_USER=alice TUSC_PASS="$pw" DEBUG=1 \
        tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "debug-mask upload failed: $out"; return 1; }
  # printf %q escapes *, so the trace shows alice:\*\*\* — strip the
  # backslashes before checking the masked form is present.
  grep -qF -- "--user alice:***" <<< "${out//\\/}" \
    || { fail "expected 'alice:***' in DEBUG output; got: $out"; return 1; }
  # The literal password must NOT appear anywhere in the transcript.
  if grep -qF -- "$pw" <<< "$out"; then
    fail "password '$pw' leaked into DEBUG output: $out"
    return 1
  fi
}

test_env_var_credentials() {
  # TUSC_USER + TUSC_PASS in the env populate basic auth without a
  # file. Verify by greppin the masked --user line out of DEBUG output.
  local f="$WORK_DIR/auth.bin"; local tdir="$WORK_DIR/auth-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=16 2>/dev/null
  local out
  out=$(TUSDIR="$tdir" TUSC_USER=alice TUSC_PASS=secret DEBUG=1 \
        tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C 2>&1) \
    || { fail "env-auth upload failed: $out"; return 1; }
  # printf %q escapes the * characters, so the trace shows
  # `--user alice:\*\*\*`. Strip backslashes before grepping.
  grep -qF -- "--user alice:***" <<< "${out//\\/}" \
    || { fail "expected --user alice:*** in DEBUG output (env creds not picked up); got: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "env-auth upload did not print success: $out"; return 1; }
}

test_resume_announces_offset() {
  # Manually create a TUS upload, PATCH half of it, then seed tusc's
  # cache to point at that URL. tusc should announce the resume offset
  # and finish the upload.
  local f="$WORK_DIR/resume.bin"; local tdir="$WORK_DIR/resume-cache"
  mkdir -p "$tdir"
  dd if=/dev/urandom of="$f" bs=1024 count=2048 2>/dev/null   # 2 MiB
  local size; size=$(wc -c < "$f" | tr -d ' ')
  local name_b64; name_b64=$(printf %s "resume.bin" | base64 | tr -d '\n')
  local hdr; hdr=$(mktemp -t resume-hdr.XXXXXX)
  curl -fsSLD "$hdr" \
    -H "Tus-Resumable: 1.0.0" \
    -H "Upload-Length: $size" \
    -H "Upload-Metadata: filename $name_b64" \
    -X POST "http://$TUSD_HOST:$TUSD_PORT/files/" >/dev/null
  local loc; loc=$(awk -F': ' 'tolower($1)=="location" {sub(/\r$/,"",$2); print $2; exit}' "$hdr")
  rm -f "$hdr"
  # PATCH first 512 KiB with a correct per-body checksum so tusd accepts.
  dd if="$f" bs=1024 count=512 2>/dev/null > "$WORK_DIR/resume-chunk"
  local sum; sum=$(openssl dgst -sha256 -binary "$WORK_DIR/resume-chunk" | base64 | tr -d '\n')
  curl -fsSL \
    -H "Tus-Resumable: 1.0.0" \
    -H "Content-Type: application/offset+octet-stream" \
    -H "Upload-Offset: 0" \
    -H "Upload-Checksum: sha256 $sum" \
    --data-binary "@$WORK_DIR/resume-chunk" -X PATCH "$loc" >/dev/null
  seed_loc_cache "$tdir" "$f" "$TUSD_HOST:$TUSD_PORT" "/files/" "resume.bin" "$loc"

  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -C)
  grep -q "Resuming at byte 524288" <<< "$out" \
    || { fail "expected resume message at byte 524288; got: $out"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" \
    || { fail "resume run did not finish; got: $out"; return 1; }
}

# Stub body used by the next two tests: returns a shell-metacharacter-
# laden Location on POST (canary for the bash-c argv bug) and always
# returns 500 on HEAD (covers "non-404 HEAD must surface").
EVIL_HEAD500_STUB='
EVIL = "http://127.0.0.1:%d/uploads/abc\x27\\; touch \x27'"$WORK_DIR"'/PWNED\x27 \\;echo \x27" % PORT
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Location", EVIL)
        self.send_header("Content-Length", "0"); self.end_headers()
    def do_HEAD(self):
        self.send_response(500)
        self.send_header("Tus-Resumable", "1.0.0")
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a, **k): pass
'

test_shell_injection_canary() {
  local port
  port=$(require_python_stub "$EVIL_HEAD500_STUB") || return $((2 - $?))
  local tdir="$WORK_DIR/inj-cache"
  rm -f "$WORK_DIR/PWNED"
  printf hello > "$WORK_DIR/inj.bin"
  # POST returns a Location with embedded shell, then tusc.sh PATCHes
  # against it. Before the argv-array fix this triggered a `touch`.
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$WORK_DIR/inj.bin" -a sha256 -C >/dev/null 2>&1 || true
  stop_python_stub
  [[ ! -e "$WORK_DIR/PWNED" ]] || fail "shell injection from server-controlled Location succeeded"
}

test_head_5xx_surfaces_error() {
  local port
  port=$(require_python_stub "$EVIL_HEAD500_STUB") || return $((2 - $?))
  local tdir="$WORK_DIR/head500-cache"; mkdir -p "$tdir"
  printf payload > "$WORK_DIR/head500.bin"
  seed_loc_cache "$tdir" "$WORK_DIR/head500.bin" "127.0.0.1:$port" "/files/" "head500.bin" \
    "http://127.0.0.1:$port/files/seeded"

  local out rc
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$WORK_DIR/head500.bin" -a sha256 -C 2>&1) && rc=0 || rc=$?
  stop_python_stub

  [[ $rc -ne 0 ]] || fail "expected non-zero exit on HEAD 500; got rc=$rc"
  grep -q "Request failed: HTTP 500" <<< "$out" \
    || fail "expected 'HTTP 500' in error output; got: $out"
}

test_errors_go_to_stderr() {
  # Hit a deliberately bad URL and confirm errors land on stderr, not stdout.
  local tdir="$WORK_DIR/stderr-cache"
  printf x > "$WORK_DIR/stderr.bin"
  local sout serr
  TUSDIR="$tdir" tusc -H "127.0.0.1:1" -f "$WORK_DIR/stderr.bin" -a sha256 -C \
    > "$WORK_DIR/stderr-out" 2> "$WORK_DIR/stderr-err" || true
  sout=$(cat "$WORK_DIR/stderr-out")
  serr=$(cat "$WORK_DIR/stderr-err")
  [[ -z "$sout" ]] || fail "stdout should be empty on error; got: $sout"
  grep -q "Request failed" <<< "$serr" \
    || fail "expected 'Request failed' on stderr; got stderr: $serr"
}

# ---- run -------------------------------------------------------------

run "binary round-trip"                test_binary_roundtrip
run "text round-trip"                  test_text_roundtrip
run "cache-hit prints Already uploaded" test_cache_hit_message
run "--restart creates a fresh upload" test_restart_replaces_upload
run "done marker beats server 404; --restart overrides" test_done_marker_trusts_local_state_over_server_404
run "-d preserves relative paths in metadata" test_dir_upload_preserves_paths
run "0-byte file uploads cleanly (skips empty PATCH)" test_zero_byte_file
run "resume works from read-only source directory" test_resume_from_readonly_source_dir
run "path with spaces survives quoting"            test_path_with_spaces
run "identical content at different paths uploads twice" test_identical_content_different_names
run "-N override sets Upload-Metadata.filename" test_name_override
run "-d re-run skips already-completed files"             test_dir_rerun_skips_completed_files
run "-d prints per-file success + URL; no tempfile leak"  test_dir_per_file_success_and_cleanup
run "-d honors set -e inside the per-file subshell"       test_dir_set_e_honored_inside_subshell
run "-d forwards -- curl passthrough args to children" test_dir_forwards_curl_passthrough
run "--creds file with only PASS is rejected"              test_creds_file_requires_both_user_and_pass
run "checksum cache invalidates on size change"            test_checksum_cache_invalidates_on_size_change
run "checksum cache invalidates on same-second rewrite"    test_checksum_cache_invalidates_on_subsecond_rewrite
run "TUSC_NOCACHE bypasses the checksum cache"             test_tusc_nocache_forces_rehash
run "--restart sends a fresh Upload-Key on POST"           test_restart_sends_fresh_upload_key
run "--locate requires --host"                             test_locate_requires_host
run "UPLOAD_KEY differs across host and base-path"          test_upload_key_includes_destination
run "-d manifest is cleaned up even on interrupt"          test_dir_manifest_cleaned_on_interrupt
run "invalid --algo is rejected by whitelist"              test_invalid_algo_rejected
run "absolute-path Location is resolved against host"      test_relative_location_is_resolved
run "path-relative Location resolves against POST URL dir" test_path_relative_location_is_resolved
run "user -- -w doesn't break internal EFFECTIVE_URL marker" test_user_w_does_not_break_effective_url_marker
run "--chunk-size sends multiple PATCH requests"            test_chunked_patch_uploads_in_multiple_patches
run "--chunk-size accepts K/M/G suffixes; rejects junk"     test_chunk_size_parser_accepts_suffixes
run "--retries inf is accepted"                              test_retries_inf_is_accepted
run "--retries with invalid values is rejected"              test_retries_invalid_value_rejected
run "--retries recovers from a transient PATCH failure"     test_retries_recover_from_transient_patch_failure
run "--retries does NOT mask 4xx responses"                 test_retries_do_not_mask_4xx
run "POST that returns no Location errors out"             test_post_with_no_location_errors
run "DEBUG drops curl -v when auth creds are in use"       test_debug_drops_curl_v_when_auth_present
run "header() returns final response Location after redirect" test_header_returns_final_response_after_redirect
run "relative Location after redirect uses effective URL"    test_relative_location_after_redirect_uses_effective_url
run "DEBUG masks passwords with shell metacharacters"      test_debug_masks_password_with_metacharacters
run "TUSC_USER/TUSC_PASS env creds are honored" test_env_var_credentials
run "resume announces byte offset"     test_resume_announces_offset
run "shell-injection canary stays cold" test_shell_injection_canary
run "HEAD 5xx surfaces as error"       test_head_5xx_surfaces_error
run "errors go to stderr, stdout empty" test_errors_go_to_stderr

echo
if [[ $FAILS -eq 0 ]]; then
  say "All $PASS test(s) PASS"
  exit 0
else
  say "$FAILS of $((PASS+FAILS)) test(s) FAILED"
  for t in "${FAILED[@]}"; do printf '    - %s\n' "$t"; done
  exit 1
fi
