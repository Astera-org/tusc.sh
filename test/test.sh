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
STUB_PID=""
cleanup() {
  local rc=$?
  for pid in "$TUSD_PID" "$STUB_PID"; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
  done
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

# Run tusc.sh from the repo root. Per-test TUSDIR isolates resume state.
tusc() { ( cd "$REPO_ROOT" && bash ./tusc.sh "$@" ); }

# Extract the URL line out of tusc.sh output.
extract_url() { awk '/^[[:space:]]*URL:[[:space:]]/ { sub(/^[[:space:]]*URL:[[:space:]]+/, ""); print; exit }'; }

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

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -S -C >/dev/null
  url="$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$fixture" -a sha256 -L -S -C | extract_url)"
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
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C >/dev/null
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C)
  grep -q "Already uploaded" <<< "$out" || fail "expected 'Already uploaded' on cache hit; got: $out"
}

test_force_replaces_upload() {
  local f="$WORK_DIR/force.bin"; local tdir="$WORK_DIR/force-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=64 2>/dev/null
  local u1 u2
  u1=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C | extract_url)
  u2=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C --force | extract_url)
  [[ -n "$u1" && -n "$u2" ]] || fail "missing URL on one of the runs: u1=$u1 u2=$u2"
  [[ "$u1" != "$u2" ]] || fail "--force did not create a fresh upload (same URL: $u1)"
}

test_stale_cache_url_recovers() {
  # Cache has a URL the server has since forgotten (404 on HEAD).
  # Should fall through to a fresh POST without surfacing an error.
  local f="$WORK_DIR/stale.bin"; local tdir="$WORK_DIR/stale-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=64 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C >/dev/null
  # Wipe tusd's upload dir to simulate server-side cleanup.
  rm -rf "$UPLOAD_DIR"; mkdir -p "$UPLOAD_DIR"
  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C)
  grep -q "Uploaded successfully" <<< "$out" \
    || fail "expected fresh upload after stale-cache 404; got: $out"
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

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -S -C >/dev/null \
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
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C) || {
    fail "0-byte upload exited non-zero"; return 1; }
  grep -q "Uploaded successfully" <<< "$out" || {
    fail "0-byte upload didn't print success: $out"; return 1; }
  local url; url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -S -C | extract_url)
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

  local key; key=$(sha256 "$rodir/big.bin")
  local upload_key
  upload_key=$(printf '%s:%s' "$key" "big.bin" | (command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256) | awk '{print $1}')
  local hostsha
  hostsha=$(printf %s "$TUSD_HOST:$TUSD_PORT/files/" \
    | (command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1) \
    | awk '{print $1}')
  printf %s "$loc" > "$tdir/loc.$upload_key.$hostsha"

  local out rc
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$rodir/big.bin" -a sha256 -S -C 2>&1) && rc=0 || rc=$?
  chmod 755 "$rodir"   # restore for cleanup
  [[ $rc -eq 0 ]] || fail "expected resume to succeed on read-only source dir; rc=$rc out=$out"
  grep -q "Uploaded successfully" <<< "$out" || fail "no success message: $out"
  # And no .part should be created next to the source.
  [[ ! -e "$rodir/big.bin.part" ]] || fail ".part leaked next to source"
}

test_path_with_spaces() {
  # File path with a space exercises every quoting hazard in the
  # cleanup trap, metadata building, and curl invocation.
  local f="$WORK_DIR/has space.bin"; local tdir="$WORK_DIR/space-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=32 2>/dev/null
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C >/dev/null \
    || fail "upload failed for path with spaces"
  local url
  url=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -L -a sha256 -S -C | extract_url)
  [[ -n "$url" ]] || fail "could not locate upload of spaced-path file"
  local got="$WORK_DIR/got.bin"
  curl -fsSL "$url" -o "$got"
  cmp -s "$f" "$got" || fail "spaced-path file bytes differ"
}

test_identical_content_different_names() {
  # Two files with identical bytes at different upload paths must
  # produce distinct uploads. Before Upload-Key was namespaced by the
  # destination name, a content-deduping server would hand the second
  # POST back the first upload's id, and the follow-up PATCH would 404.
  local root="$WORK_DIR/dupes"; local tdir="$WORK_DIR/dupes-cache"
  mkdir -p "$root/a" "$root/b"
  printf 'identical 39 bytes of fixture content..' > "$root/a/same.txt"
  printf 'identical 39 bytes of fixture content..' > "$root/b/same.txt"

  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -d -f "$root" -a sha256 -S -C >/dev/null \
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
  TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -N "deep/path/renamed.bin" -a sha256 -S -C >/dev/null
  local found=0
  for info in "$UPLOAD_DIR"/*.info; do
    grep -q '"filename":"deep/path/renamed.bin"' "$info" && { found=1; break; }
  done
  [[ $found -eq 1 ]] || fail "Upload-Metadata.filename did not honor --name override"
}

test_env_var_credentials() {
  # TUSC_USER + TUSC_PASS in the env should populate the basic-auth
  # header just like --creds <file> does.
  local f="$WORK_DIR/auth.bin"; local tdir="$WORK_DIR/auth-cache"
  dd if=/dev/urandom of="$f" bs=1024 count=16 2>/dev/null
  local out
  # DEBUG=1 prints the curl invocation with the password masked as
  # `***`; presence of `--user 'alice:***'` confirms the env creds
  # were picked up and threaded into curl's argv.
  out=$(TUSDIR="$tdir" TUSC_USER=alice TUSC_PASS=secret DEBUG=1 \
        tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C 2>&1) \
    || { fail "env-auth upload failed: $out"; return 1; }
  grep -q -- "--user alice:\\*\\*\\*" <<< "$out" \
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
  # Seed the cache. The script's cache key is UPLOAD_KEY (= the same
  # SUMALGO of "<content-hash>:<name>"), not the bare content hash.
  local key; key=$(sha256 "$f")
  local upload_key
  upload_key=$(printf '%s:%s' "$key" "resume.bin" | (command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256) | awk '{print $1}')
  local hostsha
  hostsha=$(printf %s "$TUSD_HOST:$TUSD_PORT/files/" \
    | (command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1) \
    | awk '{print $1}')
  printf %s "$loc" > "$tdir/loc.$upload_key.$hostsha"

  local out
  out=$(TUSDIR="$tdir" tusc -H "$TUSD_HOST:$TUSD_PORT" -f "$f" -a sha256 -S -C)
  grep -q "Resuming at byte 524288" <<< "$out" \
    || fail "expected resume message at byte 524288; got: $out"
  grep -q "Uploaded successfully" <<< "$out" \
    || fail "resume run did not finish; got: $out"
}

# Stub server for the next two tests: returns malicious Location on POST
# and 500 on HEAD. Lets us exercise script paths that depend on the
# server behavior tusd won't reproduce on its own.
start_stub_server() { # $1 = port
  local port="$1"
  cat > "$WORK_DIR/stub.py" <<PY
import http.server, socketserver, sys
PORT = int(sys.argv[1])
# Crafted Location with shell metacharacters. If tusc.sh re-parses this
# through a shell (the historical bash -c bug), the touch fires.
EVIL = "http://127.0.0.1:%d/uploads/abc'\\; touch '$WORK_DIR/PWNED' \\;echo '" % PORT
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(201)
        self.send_header('Tus-Resumable', '1.0.0')
        self.send_header('Location', EVIL)
        self.send_header('Content-Length', '0')
        self.end_headers()
    def do_HEAD(self):
        # Always 500 — exercise the "non-404 HEAD must surface" path.
        self.send_response(500)
        self.send_header('Tus-Resumable', '1.0.0')
        self.send_header('Content-Length', '0')
        self.end_headers()
    def log_message(self, *a, **k): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', PORT), H) as s:
    s.serve_forever()
PY
  python3 "$WORK_DIR/stub.py" "$port" >/dev/null 2>&1 &
  STUB_PID=$!
  # Give the stub a moment to come up.
  for _ in $(seq 1 50); do
    curl -sS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && return 0
    sleep 0.05
  done
  return 0
}

test_shell_injection_canary() {
  command -v python3 >/dev/null || { say "    skip: python3 not available"; return 0; }
  local port=$((40000 + RANDOM % 10000))
  start_stub_server "$port"
  local tdir="$WORK_DIR/inj-cache"
  rm -f "$WORK_DIR/PWNED"
  printf hello > "$WORK_DIR/inj.bin"
  # POST returns a Location with embedded shell, then tusc.sh PATCHes
  # against it. Before the argv-array fix this triggered a `touch`.
  TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$WORK_DIR/inj.bin" -a sha256 -S -C >/dev/null 2>&1 || true
  kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""
  [[ ! -e "$WORK_DIR/PWNED" ]] || fail "shell injection from server-controlled Location succeeded"
}

test_head_5xx_surfaces_error() {
  command -v python3 >/dev/null || { say "    skip: python3 not available"; return 0; }
  local port=$((40000 + RANDOM % 10000))
  start_stub_server "$port"
  local tdir="$WORK_DIR/head500-cache"; mkdir -p "$tdir"
  printf payload > "$WORK_DIR/head500.bin"
  # Seed cache: cache key is UPLOAD_KEY = sha256("<content-hash>:<name>").
  local key; key=$(sha256 "$WORK_DIR/head500.bin")
  local upload_key
  upload_key=$(printf '%s:%s' "$key" "head500.bin" | (command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256) | awk '{print $1}')
  local hostsha
  hostsha=$(printf %s "127.0.0.1:$port/files/" \
    | (command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1) \
    | awk '{print $1}')
  printf %s "http://127.0.0.1:$port/files/seeded" > "$tdir/loc.$upload_key.$hostsha"

  local out rc
  out=$(TUSDIR="$tdir" tusc -H "127.0.0.1:$port" -f "$WORK_DIR/head500.bin" -a sha256 -S -C 2>&1) && rc=0 || rc=$?
  kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""

  [[ $rc -ne 0 ]] || fail "expected non-zero exit on HEAD 500; got rc=$rc"
  grep -q "Request failed: HTTP 500" <<< "$out" \
    || fail "expected 'HTTP 500' in error output; got: $out"
}

test_errors_go_to_stderr() {
  # Hit a deliberately bad URL and confirm errors land on stderr, not stdout.
  local tdir="$WORK_DIR/stderr-cache"
  printf x > "$WORK_DIR/stderr.bin"
  local sout serr
  TUSDIR="$tdir" tusc -H "127.0.0.1:1" -f "$WORK_DIR/stderr.bin" -a sha256 -S -C \
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
run "--force creates a fresh upload"   test_force_replaces_upload
run "stale cache URL recovers"         test_stale_cache_url_recovers
run "-d preserves relative paths in metadata" test_dir_upload_preserves_paths
run "0-byte file uploads cleanly (skips empty PATCH)" test_zero_byte_file
run "resume works from read-only source directory" test_resume_from_readonly_source_dir
run "path with spaces survives quoting"            test_path_with_spaces
run "identical content at different paths uploads twice" test_identical_content_different_names
run "-N override sets Upload-Metadata.filename" test_name_override
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
