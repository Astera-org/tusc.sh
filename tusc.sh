#!/usr/bin/env bash
#
# TUS client 1.0.0 protocol implementation for bash.
#
# Author:
#   Jitendra Adhikari <jiten.adhikary@gmail.com>
#
# Contributors:
#   Astera Institute <https://astera.org>  (macOS portability, jq removal)
#
# Originally hosted at https://github.com/adhocore/tusc.sh
#
# Licensed under the MIT License. See the LICENSE file for details.
#

if [[ -f $HOME/.tus.dbg ]]; then set -ex; else set -e; fi

# Resolve the script's own path with realpath (portable on macOS 12.3+
# and Linux coreutils) rather than `readlink -f`, which BSD readlink
# historically did not support.
FULL=$(realpath "$0")
TUSC=$(basename "$0")
SPINID=0
CURLARGS=()      # passthrough curl args captured after `--`
FILEPART_TMP=""  # tracked here so on-exit can remove it even when interrupted

ISOK=0    # is last request ok?
STATUS=   # last response status code

# stat helpers (GNU vs BSD)
if stat -c %s /dev/null >/dev/null 2>&1; then
  fsize()  { stat -c %s "$1"; }
  fmtime() { stat -c %Y "$1"; }
else
  fsize()  { stat -f %z "$1"; }
  fmtime() { stat -f %m "$1"; }
fi

# unwrapped base64 (BSD base64 has no -w, GNU wraps at 76 by default)
b64() { base64 | tr -d '\n'; }

# ${algo}sum fallback to shasum (macOS ships shasum, not sha1sum/sha256sum)
checksum() # $1 = algo (sha1|sha256|...), $2 = file -> prints "<hex>  <file>"
{
  if command -v "${1}sum" >/dev/null 2>&1; then
    "${1}sum" "$2"
  else
    shasum -a "${1#sha}" "$2"
  fi
}

# Base64-of-raw-digest for the TUS Upload-Checksum header. Per
# https://tus.io/protocols/resumable-upload, the value is the base64
# encoding of the *raw* digest bytes of the current request body — not
# base64 of the hex string, and not the full-file hash on a partial
# PATCH. Returns empty string if openssl isn't available; callers
# treat that as "omit the header".
body-checksum-b64() # $1 = algo, $2 = file (the actual PATCH body)
{
  command -v openssl >/dev/null 2>&1 || return 0
  openssl dgst "-$1" -binary "$2" 2>/dev/null | base64 | tr -d '\n'
}

# message helpers
# Arguments: $1=text, $2=color, $3=style, $4=exit-code (optional),
# $5=target fd (1=stdout default, 2=stderr).
line() {
  local fd=${5:-1}
  if [[ $NOCOLOR ]]; then
    printf '%b\n' "$1" >&"$fd"
  else
    printf '\033[%s;%sm%b\033[0m\n' "${3:-0}" "$2" "$1" >&"$fd"
  fi
  [[ "$4" == "" ]] || exit $4
}
error()   { line "$1" 31 0 "$2" 2; }    # red,  stderr
ok()      { line "${1:-  Done}" 32 0 "$2"; }
info()    { line "$1" 33 0 "$2"; }
comment() { line "$1" 30 1 "$2"; }      # dim,  stdout (used to render --help text)
debug()   { line "$1" 30 1 "$2" 2; }    # dim,  stderr (DEBUG=1 trace lines)

# show version
version() { echo v2.0.0; }

# update tusc
update()
{
  NEWVER=`curl -fsSL https://raw.githubusercontent.com/Astera-org/tusc.sh/main/VERSION`
  [[ "v$NEWVER" == "$(version)" ]] && ok "Already latest version" 0

  info "Updating $TUSC ..."
  curl -fsSLo "$FULL" https://raw.githubusercontent.com/Astera-org/tusc.sh/main/tusc.sh
  ok "  Done [${NEWVER}]"
}

# show usage
usage()
{
  cat << USAGE
  $TUSC $(info `version`) | $(ok "(c) Jitendra Adhikari") | https://github.com/adhocore
  $TUSC is bash implementation of tus-client (https://tus.io).
  With contributions from $(ok "Astera Institute") (https://astera.org).

  $(ok Usage:)
    $TUSC <--options>
    $TUSC <host> <file> [algo]

  $(ok Options:)
    $(info "-a --algo")      $(comment "The algorigthm for key &/or checksum.")
                   $(comment "(Eg: sha1, sha256)")
    $(info "-b --base-path") $(comment "The tus-server base path (Default: '/files/').")
    $(info "-c --creds")     $(comment "File with credentials; user and pass in shell syntax:")
                     $(line 'USER="my_user"' 36)
                     $(line 'PASS="my_pass"' 36)
    $(info "-C --no-color")  $(comment "Donot color the output (Useful for parsing output).")
    $(info "-f --file")      $(comment "The file to upload (or directory, with -d).")
    $(info "-F --force")     $(comment "Ignore the cached upload URL; start a fresh upload.")
    $(info "-N --name")      $(comment "Override the filename sent in Upload-Metadata.")
                   $(comment "(May contain slashes; server gets the literal value.)")
    $(info "-d --dir")       $(comment "Treat --file as a directory; upload every file under it,")
                   $(comment "preserving the relative path in Upload-Metadata.filename.")
    $(info "-h --help")      $(comment "Show help information and usage.")
    $(info "-H --host")      $(comment "The tus-server host where file is uploaded.")
    $(info "-L --locate")    $(comment "Locate the uploaded file in tus-server.")
    $(info "-S --no-spin")   $(comment "Donot show the spinner (Useful for parsing output).")
    $(info "-u --update")    $(comment "Update tusc to latest version.")
    $(info "   --version")   $(comment "Print the current tusc version.")

  $(ok Environment:)
    $(info "DEBUG=1")        $(comment "Verbose curl + show debug headers on stderr.")
    $(info "TUSDIR")         $(comment "Cache dir for resume state and file checksums.")
                   $(comment "(Default: \$TMPDIR/tusc.<uid>/. Delete to force a fresh upload.)")

  $(ok Examples:)
    $TUSC --help                           # shows this help
    $TUSC --update                         # updates itself
    $TUSC --version                        # prints current version of itself
    $TUSC    0:1080    ww.mp4              # uploads ww.mp4 to http://0.0.0.0:1080/files/
    $TUSC -H 0:1080 -f ww.mp4              # same as above
    $TUSC -H 0:1080 -f ww.mp4 -a sha256    # same as above but uses sha256 algo for key/checksum
    $TUSC -H 0:1080 -f ww.mp4 -b /store/   # uploads ww.mp4 to http://0.0.0.0:1080/store/
USAGE
}

# Resume-state cache: one file per key under $TMPDIR/tusc.<uid>/, keyed
# by a sha1 of the logical key string so any characters (slashes,
# colons, ...) are safe in filenames. Avoids depending on jq. The cache
# lives under the system temp dir intentionally — resume survives the
# duration of a session but the OS will reclaim it on reboot/cleanup.
# Override with $TUSDIR for tests or single-user systems.
if [[ -z "${TUSDIR:-}" ]]; then
  TMP="${TMPDIR:-/tmp}"
  TUSDIR="${TMP%/}/tusc.${UID:-$(id -u)}"
fi

# Hash an arbitrary string to a hex digest, for use as a filename.
strhash() # $1 = string
{
  if command -v sha1sum >/dev/null 2>&1; then
    printf %s "$1" | sha1sum | awk '{print $1}'
  else
    printf %s "$1" | shasum -a 1 | awk '{print $1}'
  fi
}

# Cached file checksum (skip rehashing on resume).
cache-checksum-get() # $1 = "<file>:<mtime>", $2 = algo
{
  local f="$TUSDIR/ck.$(strhash "$1").$2"
  [[ -f "$f" ]] && cat "$f"
  return 0
}
cache-checksum-set() # $1 = "<file>:<mtime>", $2 = algo, $3 = hex digest
{
  ensure-tusdir
  printf %s "$3" > "$TUSDIR/ck.$(strhash "$1").$2"
}

# Cached resume URL for a (checksum-key, host+base-path) pair. Base-path
# is part of the key so changing it doesn't reuse a stale upload URL.
cache-loc-get() # $1 = host+basepath, $2 = key
{
  local f="$TUSDIR/loc.$2.$(strhash "$1")"
  [[ -f "$f" ]] && cat "$f"
  return 0
}
cache-loc-set() # $1 = host+basepath, $2 = key, $3 = url
{
  ensure-tusdir
  printf %s "$3" > "$TUSDIR/loc.$2.$(strhash "$1")"
}

ensure-tusdir()
{
  [[ -d "$TUSDIR" ]] && return 0
  mkdir -p "$TUSDIR"
  chmod 700 "$TUSDIR"
}

locate() # $1 = HOST, $2 = BASEPATH, $3 = key
{
  cache-loc-get "$1$2" "$3"
}

# Carve the tail of a file starting at byte offset $1 into a temp file
# under $TUSDIR (a writable, per-user dir). We previously wrote
# "$3.part" next to the source, which fails on read-only sources and
# clobbers any existing .part file. Records the path in $FILEPART_TMP
# so the EXIT trap can remove it even if we're interrupted.
filepart() # $1 = start_byte, $2 = byte_length (unused; always remainder), $3 = file
{
  ensure-tusdir
  FILEPART_TMP=$(mktemp "$TUSDIR/part.XXXXXXXX")
  tail -c +"$(( $1 + 1 ))" "$3" > "$FILEPART_TMP"
  printf '%s\n' "$FILEPART_TMP"
}

# http request
#
# Takes curl arguments as separate positional parameters (an argv
# array) and invokes curl directly — never via `bash -c` and never
# through a concatenated shell string. This is deliberate: the TUS
# `Location` header we cache and pass back as the upload URL is
# server-controlled, and a malicious or compromised server could
# otherwise embed shell metacharacters that would execute during the
# next PATCH/HEAD.
request()
{
  echo > "$HEADER"

  # Scan for the request shape so we can adjust verbosity. Look at the
  # CLI tokens we'll pass to curl — both --head and PATCH appear as
  # standalone args (--head is a single flag; PATCH follows --request).
  local arg is_head=0 is_patch=0
  for arg in "$@"; do
    case "$arg" in
      --head) is_head=1 ;;
      PATCH)  is_patch=1 ;;
    esac
  done

  # Build the curl argv array.
  local cmd=(curl)
  [[ $DEBUG ]] && cmd+=(-v)
  # -sS = silent + show errors. For the PATCH (the only large body
  # transfer) we drop -s so curl's progress meter writes to stderr.
  if [[ $is_patch -eq 1 && -z $NOSPIN && -z $DEBUG ]]; then
    cmd+=(-S)
  else
    cmd+=(-sS)
  fi
  cmd+=(-L -D "$HEADER" -H "Tus-Resumable: 1.0.0")
  [[ $CREDS ]] && cmd+=(--basic --user "$USER:$PASS")
  # CURLARGS is a user-supplied passthrough captured as an array from
  # the "--" sentinel during argv parsing. Safe to splat directly.
  [[ ${#CURLARGS[@]} -gt 0 ]] && cmd+=("${CURLARGS[@]}")
  cmd+=("$@")

  if [[ $DEBUG ]]; then
    local pretty
    pretty=$(printf '%q ' "${cmd[@]}")
    [[ $CREDS ]] && pretty=${pretty//$PASS/***}
    debug "> $pretty"
  fi

  # For PATCH and DEBUG, let stderr flow to the terminal (progress meter
  # / -v transcript). Otherwise fold stderr into the captured body so
  # curl's transport errors land in the request-failed message. Suspend
  # `set -e` around the substitution so a curl transport failure (curl
  # exits non-zero, e.g. ECONNREFUSED) doesn't abort the script before
  # we get to inspect $STATUS and emit a useful error.
  set +e
  if [[ $DEBUG || $is_patch -eq 1 ]]; then
    BODY=$("${cmd[@]}")
  else
    BODY=$("${cmd[@]}" 2>&1)
  fi
  set -e

  STATUS=$(awk '/^HTTP\// { match($0, /[0-9][0-9][0-9]/); s = substr($0,RSTART,3) } END { print s }' "$HEADER")
  if [[ "$STATUS" == 20* ]]; then ISOK=1 RET=0; else ISOK=0 RET=1; fi

  # For a HEAD probe, only 404/410 are "expected cache misses" that the
  # caller can recover from by creating a new upload. Anything else —
  # auth failure, server error, missing status (curl couldn't even
  # parse a response) — is a real problem and must surface.
  local suppress=0
  if [[ $is_head -eq 1 && ("$STATUS" == "404" || "$STATUS" == "410") ]]; then
    suppress=1
  fi

  if [[ $ISOK -eq 0 && $suppress -eq 0 ]]; then
    # Last arg in the curl argv is the URL we hit.
    local target=${cmd[${#cmd[@]}-1]}
    local msg="✖ Request failed: HTTP ${STATUS:-?} on $target"
    [[ -n "$BODY" ]] && msg="$msg"$'\n'"$BODY"
    error "$msg" 1
  fi
  return $RET
}

# http response header (case-insensitive lookup against the raw header file)
header() # $1 = key
{
  [[ -f "$HEADER" ]] || return 0
  awk -v k="$1" '
    BEGIN { k = tolower(k) }
    /^HTTP\// { next }
    {
      sub(/\r$/, "")
      i = index($0, ":")
      if (i == 0) next
      n = substr($0, 1, i - 1)
      v = substr($0, i + 1)
      sub(/^ +/, "", v)
      if (tolower(n) == k) { print v; exit }
    }
  ' "$HEADER"
}

# show spinner and mark its pid
spinner()
{
  [[ $NOSPIN ]] && return 0
  do-spin &
  SPINID=$!
  disown
}

# do spin (credits: https://www.shellscript.sh/tips/spinner/)
do-spin()
{
  local chars="+/|\\-+/|\\-"
  while :; do
    for i in `seq 0 9`; do
      echo -n "${chars:$i:1}" && echo -en "\010" && sleep 0.1
    done
  done
}

no-spinner()
{
  [[ $NOSPIN ]] && return 0
  local PID=$SPINID
  SPINID=0
  if [[ $PID -ne 0 ]]; then
    kill $PID 2> /dev/null
    wait $PID 2> /dev/null
  fi
  # Overwrite whatever glyph the spinner left at the cursor with a
  # space, then return to col 0. Works without ANSI support.
  printf '\r  \r' >&2
}

# exit handler
on-exit()
{
  no-spinner
  if [[ $OFFSET ]]; then
    # Prefer Upload-Offset from the most recent response, but don't
    # clobber a known-good $OFFSET when the response doesn't carry the
    # header (e.g. tusd's 201 to a 0-byte POST has no Upload-Offset).
    local hdr_offset
    hdr_offset=$(header "Upload-Offset")
    [[ -n "$hdr_offset" ]] && OFFSET=$hdr_offset
    LEFTOVER=$((SIZE - ${OFFSET:-0}))
  fi
  rm -f -- "$FILEPART_TMP" "$HEADER0" "$HEADER"
  [[ $OFFSET ]] || return 0

  if [[ $LEFTOVER -eq 0 ]]; then
    if [[ $SKIPPED ]]; then
      ok "ℹ Already uploaded — skipping (re-run with --force to overwrite)."
    else
      ok "✔ Uploaded successfully!"
    fi
  else
    error "✖ Unfinished upload, please rerun the command to resume." 1
  fi
  info "URL: $TUSURL"
}

# argv parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a | --algo) SUMALGO="$2"; shift 2 ;;
    -b | --base-path) BASEPATH="$2"; shift 2 ;;
    -c | --creds) CREDS="$2"; shift 2 ;;
    -C | --no-color) NOCOLOR=1; shift ;;
    -f | --file) FILE="$2"; shift 2 ;;
    -h | --help | help) usage $1; exit 0 ;;
    -H | --host) HOST="$2"; shift 2 ;;
    -L | --locate) LOCATE=1; shift ;;
    -S | --no-spin) NOSPIN=1; shift ;;
    -F | --force) FORCE=1; shift ;;
    -d | --dir) DIRMODE=1; shift ;;
    -N | --name) NAME_OVERRIDE="$2"; shift 2 ;;
    -u | --update) update; exit 0 ;;
         --version | version) version; exit 0 ;;
    --) shift; CURLARGS=("$@"); break ;;
    *) if [[ $HOST ]]; then
        if [[ $FILE ]]; then SUMALGO="${SUMALGO:-$1}"; else FILE="$1"; fi
      else HOST=$1; fi
      shift ;;
  esac
done

[[ $CREDS ]] && { [[ -f $CREDS ]] && source $CREDS && [[ $PASS ]] || error "--creds file couldn't be loaded" 1; }
[[ $HOST ]] || [[ $LOCATE ]] || error "--host required" 1
[[ $FILE ]] || error "--file required" 1

# Directory mode: --file is a directory; upload each regular file under
# it one at a time, re-exec'ing this script per file with the relative
# path passed in --name (which is what gets base64'd into
# Upload-Metadata.filename). The base-path stays fixed; the source
# directory's basename becomes the first path segment of every name so
# the directory itself materializes at the destination (instead of
# its contents being splayed into the upload root).
if [[ $DIRMODE ]]; then
  ROOT=$(realpath "$FILE") || error "--file '$FILE' not found" 1
  [[ -d "$ROOT" ]] || error "--file must be a directory when -d/--dir is given" 1
  ROOT="${ROOT%/}"
  ROOT_NAME=$(basename "$ROOT")

  total=0 idx=0 fails=0
  while IFS= read -r -d '' f; do total=$((total+1)); done \
    < <(find "$ROOT" -type f -print0)
  [[ $total -eq 0 ]] && error "no files under '$ROOT'" 1
  info "Uploading $total file(s) from $ROOT (as $ROOT_NAME/...)"

  while IFS= read -r -d '' f; do
    idx=$((idx+1))
    rel="$ROOT_NAME/${f#$ROOT/}"
    info "[$idx/$total] $rel"
    bash "$FULL" \
      ${NOCOLOR:+--no-color} \
      ${NOSPIN:+--no-spin} \
      ${FORCE:+--force} \
      ${SUMALGO:+--algo "$SUMALGO"} \
      ${CREDS:+--creds "$CREDS"} \
      ${BASEPATH:+--base-path "$BASEPATH"} \
      --host "$HOST" \
      --file "$f" \
      --name "$rel" \
    || fails=$((fails+1))
  done < <(find "$ROOT" -type f -print0 | LC_ALL=C sort -z)

  [[ $fails -gt 0 ]] && error "$fails file(s) failed to upload" 1
  ok "✔ $total file(s) uploaded from $ROOT"
  exit 0
fi

trap on-exit EXIT

[[ -f $FILE ]] || error "--file doesn't exist" 1

SUMALGO=${SUMALGO:-sha1}
[[ $SUMALGO == "sha"* ]] || error "--algo '$SUMALGO' not supported" 1

FILE=`realpath "$FILE"`  NAME=${NAME_OVERRIDE:-`basename "$FILE"`}  SIZE=`fsize "$FILE"`  MTIME=`fmtime "$FILE"`
HEADER=`mktemp -t tus.XXXXXXXXXX`

# calc &/or cache key and checksum
KEY=$(cache-checksum-get "$FILE:$MTIME" "$SUMALGO")
if [[ -z "$KEY" ]]; then
  [[ $DEBUG ]] && debug "> checksum $SUMALGO $FILE"
  spinner
  read -r KEY _ <<< "$(checksum "$SUMALGO" "$FILE")"
  no-spinner
  cache-checksum-set "$FILE:$MTIME" "$SUMALGO" "$KEY"
fi

# The Upload-Key header we send (and the URL we cache against) must be
# unique per (content, destination). If we used the bare content
# digest, two distinct files with identical bytes — common with empty
# placeholders, stub files, or fixture data — would collide: a
# content-deduping server may hand the second POST back an
# already-finalized upload id, causing the follow-up PATCH to fail
# 404. Mix the destination name in so identical content at different
# upload paths stays distinct, while a re-run of the same file at the
# same path still keys identically and resumes.
UPLOAD_KEY=$(printf '%s:%s' "$KEY" "$NAME" \
  | (command -v "${SUMALGO}sum" >/dev/null 2>&1 && "${SUMALGO}sum" || shasum -a "${SUMALGO#sha}") \
  | awk '{print $1}')

[[ $DEBUG ]] && info "HOST  : $HOST\nHEADER: $HEADER\nFILE  : $NAME\nSIZE  : $SIZE\nKEY   : $KEY\nUPLOAD_KEY: $UPLOAD_KEY"

# head request
BASEPATH=${BASEPATH:-/files/}
TUSURL=$(locate "$HOST" "$BASEPATH" "$UPLOAD_KEY")
# --force ignores any cached upload URL so we always start a fresh POST.
[[ $FORCE ]] && TUSURL=""
[[ $LOCATE ]] && info "URL: $TUSURL" && [[ -n "$TUSURL" ]]; [[ $LOCATE ]] && exit $?
# Probe the cached URL with a HEAD. A non-2xx here just means the
# server forgot the upload (tusd's retention expired, host cleaned up,
# etc.) — fall through to a fresh POST. `|| true` keeps `set -e` from
# aborting the script silently on the HEAD's non-zero return.
[[ -n "$TUSURL" ]] && { request --head "$TUSURL" || true; }

FILEPART=$FILE
if [[ -n "$TUSURL" ]] && [[ $ISOK -eq 1 ]]; then
  OFFSET=$(header "Upload-Offset") LEFTOVER=$((SIZE - OFFSET))
  # Server reports this upload is already complete — short-circuit and
  # tell the user it was a no-op (re-run with --force to upload again).
  [[ $LEFTOVER -eq 0 ]] && SKIPPED=1 && exit 0
  if [[ $OFFSET -gt 0 ]]; then
    PCT=$(( OFFSET * 100 / SIZE ))
    info "↻ Resuming at byte $OFFSET / $SIZE (${PCT}%)"
    [[ $DEBUG ]] && debug "> filepart $OFFSET $LEFTOVER $FILE"
    spinner && FILEPART=`filepart $OFFSET $LEFTOVER $FILE` && no-spinner
  fi

# create request
else
  OFFSET=0 LEFTOVER=$SIZE
  META="filename $(printf %s "$NAME" | b64)"
  [[ $CREDS ]] && META="$META,user $(printf %s "$USER" | b64)"
  # No Upload-Checksum on the POST: the create request has no body.
  request \
    -H "Upload-Length: $SIZE" \
    -H "Upload-Key: $UPLOAD_KEY" \
    -H "Upload-Metadata: $META" \
    -X POST "$HOST$BASEPATH"

  # save location config
  TUSURL=$(header "Location")
  [[ $TUSURL ]] && cache-loc-set "$HOST$BASEPATH" "$UPLOAD_KEY" "$TUSURL"

  # 0-byte file: the POST already created the upload at its terminal
  # state (Upload-Length: 0). Sending a follow-up PATCH with an empty
  # body is wasteful and some servers reject it with 404 ("upload not
  # found") because there's nothing left to write. Skip the PATCH.
  if [[ $SIZE -eq 0 ]]; then
    OFFSET=0
    exit 0
  fi
fi

# curl's built-in progress meter does the job for the PATCH (visible in
# request() unless -S/--no-spin or DEBUG=1 is set), so don't start the
# bash spinner here.

# patch request — `--upload-file` already sets Content-Length from the
# file size; an explicit `Transfer-Encoding: chunked` here is invalid
# over HTTP/2 (e.g. behind an AWS ELB) and makes curl send chunk-framed
# bytes inside the H2 body, tripping a 400 at the load balancer.
#
# Per the TUS spec, Upload-Checksum is for the *current request body*.
# That means we have to digest FILEPART (the partial slice on resume),
# not the whole file. Skip the header if openssl isn't available — the
# spec makes Upload-Checksum optional.
PATCH_ARGS=(
  -H "Content-Type: application/offset+octet-stream"
  -H "Content-Length: $LEFTOVER"
  -H "Upload-Offset: $OFFSET"
)
PATCH_SUM=$(body-checksum-b64 "$SUMALGO" "$FILEPART")
[[ -n "$PATCH_SUM" ]] && PATCH_ARGS+=(-H "Upload-Checksum: $SUMALGO $PATCH_SUM")
PATCH_ARGS+=(--upload-file "$FILEPART" --request PATCH "$TUSURL")
request "${PATCH_ARGS[@]}" || error "Request failed" 1

# tusd (and any spec-compliant server) returns the final Upload-Offset
# in the PATCH 204 response. If we're already at SIZE, finish up; the
# trap will report success from $OFFSET.
PATCH_OFFSET=$(header "Upload-Offset")
if [[ "$PATCH_OFFSET" == "$SIZE" ]]; then
  OFFSET=$PATCH_OFFSET
  exit 0
fi

# Fallback: some servers reply before fully committing. Poll HEAD until
# the upload settles or we give up. `|| true` keeps `set -e` from
# aborting the script silently when the server returns a non-2xx HEAD
# (e.g. Astera's gateway returns 404 once an upload is finalized).
HEADER0=$HEADER; HEADER=`mktemp -t tus.XXXXXXXXXX`
for _ in $(seq 1 30); do
  request --head "$TUSURL" > /dev/null || true
  POLL_OFFSET=$(header "Upload-Offset")
  if [[ "$POLL_OFFSET" == "$SIZE" ]]; then
    OFFSET=$POLL_OFFSET
    exit 0
  fi
  sleep 2
done
error "Upload did not finalize after polling" 1
