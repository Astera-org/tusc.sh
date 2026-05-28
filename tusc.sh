#!/usr/bin/env bash
#
# TUS client 1.0.0 protocol implementation for bash.
#
# Author:
#   Jitendra Adhikari <jiten.adhikary@gmail.com>
#
# Contributors:
#   Astera Institute <https://astera.org>
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
FILEPART_TMP=""  # per-upload tempfile, removed by on-exit even when interrupted
MANIFEST_TMP=""  # dir-mode file list, removed by on-exit even when interrupted

ISOK=0    # is last request ok?
STATUS=   # last response status code

# stat helpers (GNU vs BSD). fmtime_fine returns mtime with
# nanosecond precision where the OS / filesystem supports it; we mix
# it into the checksum cache key so a same-second rewrite of a file
# (e.g. editor "save twice" within 1s, or `cp -p` preserving mtime
# *and* size) still invalidates the cached digest.
if stat -c %s /dev/null >/dev/null 2>&1; then
  fsize() { stat -c %s "$1"; }
  fmtime_fine() {
    # GNU stat: %y -> "YYYY-MM-DD HH:MM:SS.NNNNNNNNN ±HHMM"
    local sec frac
    sec=$(stat -c %Y "$1")
    frac=$(stat -c %y "$1" | awk '{print $2}' | awk -F. '{print $2}')
    printf '%s.%s' "$sec" "${frac:-0}"
  }
else
  fsize() { stat -f %z "$1"; }
  fmtime_fine() { stat -f %Fm "$1"; }   # BSD: "<seconds>.<nanoseconds>"
fi

# unwrapped base64 (BSD base64 has no -w, GNU wraps at 76 by default)
b64() { base64 | tr -d '\n'; }

# Hex-digest helpers. Prefer `<algo>sum` (Linux) and fall back to
# `shasum -a <N>` (macOS, ships shasum but not sha1sum/sha256sum).
# Both helpers capture the digest command's full output, return non-zero
# if the command failed or produced no digest, and print the hex on
# stdout. Don't pipe into awk inside the function: awk masks the
# upstream command's failure under non-pipefail bash, and an unknown
# algorithm would silently yield an empty digest.
hash_file_hex() # $1 = algo (sha1|sha256|...), $2 = file -> "<hex>"
{
  local out
  if command -v "${1}sum" >/dev/null 2>&1; then
    out=$("${1}sum" "$2") || return 1
  else
    out=$(shasum -a "${1#sha}" "$2") || return 1
  fi
  out=${out%% *}
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}
hash_stdin_hex() # $1 = algo, reads stdin -> "<hex>"
{
  local out
  if command -v "${1}sum" >/dev/null 2>&1; then
    out=$("${1}sum") || return 1
  else
    out=$(shasum -a "${1#sha}") || return 1
  fi
  out=${out%% *}
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
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

# Resolve a TUS Location header against a base URL. Handles the four
# common reference forms (absolute, protocol-relative, absolute-path,
# path-relative) — does NOT do RFC-3986 dot-segment normalization
# ("../" / "./" stay literal in the output). Callers pass the
# effective POST URL (curl's %{url_effective}, which already reflects
# any -L redirects) so relative resolution sees the right base.
resolve_url() # $1 = base URL, $2 = Location reference
{
  local base=$1 ref=$2
  case "$ref" in
    http://*|https://*) printf '%s\n' "$ref"; return ;;
  esac
  # Ensure base has a scheme so the regex below can pull it.
  case "$base" in
    http://*|https://*) ;;
    *) base="http://$base" ;;
  esac
  local scheme="http:"
  [[ "$base" =~ ^(https?): ]] && scheme="${BASH_REMATCH[1]}:"
  case "$ref" in
    //*) printf '%s%s\n' "$scheme" "$ref"; return ;;
  esac
  local sch_auth=""
  # `[^/]+` after the scheme handles bracketed IPv6 hosts
  # (`http://[::1]:1080/`) since `]` is a valid bracket-expression
  # char, not a delimiter for us.
  [[ "$base" =~ ^(https?://[^/]+) ]] && sch_auth="${BASH_REMATCH[1]}"
  case "$ref" in
    /*) printf '%s%s\n' "$sch_auth" "$ref"; return ;;
  esac
  # Path-relative: combine with base's directory portion. Strip the
  # scheme+authority by length (not by glob pattern — `[`/`]` in IPv6
  # hosts confuses ${var#pattern}).
  local base_path="${base:${#sch_auth}}"
  base_path="${base_path%%[?#]*}"
  case "$base_path" in
    */*) base_path="${base_path%/*}/" ;;
    *)   base_path="/" ;;
  esac
  printf '%s%s%s\n' "$sch_auth" "$base_path" "$ref"
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
error()   { REPORTED=1; line "$1" 31 0 "$2" 2; }    # red,  stderr; suppresses trap's "unfinished" hint
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
  # Download to a sibling temp file, lint it, then atomic rename.
  # Writing straight onto $FULL leaves a corrupted script behind if
  # the curl is interrupted or the body is truncated.
  local tmp; tmp=$(mktemp "$FULL.update.XXXXXXXX")
  if ! curl -fsSLo "$tmp" https://raw.githubusercontent.com/Astera-org/tusc.sh/main/tusc.sh; then
    rm -f -- "$tmp"
    error "✖ Update download failed" 1
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    error "✖ Downloaded script failed bash -n syntax check; refusing to install" 1
  fi
  chmod 755 "$tmp"
  mv -f -- "$tmp" "$FULL"
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
    $(info "-R --restart")   $(comment "Ignore the cached upload URL; start a fresh upload.")
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
    $(info "DEBUG=1")        $(comment "Show the script's request trace on stderr. Also enables")
                   $(comment "curl -v unless basic-auth creds are in use (-v leaks the")
                   $(comment "Authorization header).")
    $(info "TUSC_DEBUG_UNSAFE=1") $(comment "Re-enable curl -v when DEBUG=1 + creds. Use only for")
                   $(comment "debugging against trusted endpoints — exposes Authorization.")
    $(info "TUSDIR")         $(comment "Cache dir for resume state and file checksums.")
                   $(comment "(Default: \$TMPDIR/tusc.<uid>/. Delete to force a fresh upload.)")
    $(info "TUSC_NOCACHE=1") $(comment "Always re-hash the file; ignore the checksum cache.")
    $(info "TUSC_USER")      $(comment "Basic-auth username (alternative to --creds file).")
    $(info "TUSC_PASS")      $(comment "Basic-auth password (paired with TUSC_USER).")

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
strhash() { printf %s "$1" | hash_stdin_hex sha1; }

# Cached file checksum (skip rehashing on resume). Key is opaque
# from the helper's perspective; callers compose path+mtime+size so a
# mtime-preserving rewrite (different size) invalidates the entry.
cache-checksum-get() # $1 = cache key string, $2 = algo
{
  local f="$TUSDIR/ck.$(strhash "$1").$2"
  [[ -f "$f" ]] && cat "$f"
  return 0
}
cache-checksum-set() # $1 = cache key string, $2 = algo, $3 = hex digest
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
  # Also stash the caller's last argument as the request target — by
  # convention that's the URL — so error reporting can still name it
  # if the internal `-w` marker is the literal last element of cmd[].
  local arg is_head=0 is_patch=0 target_url=""
  for arg in "$@"; do
    case "$arg" in
      --head) is_head=1 ;;
      PATCH)  is_patch=1 ;;
    esac
    target_url=$arg
  done

  # Build the curl argv array.
  local cmd=(curl)
  # `curl -v` prints the request transcript including the
  # `Authorization:` header. Skip it when basic-auth creds are in use
  # so DEBUG traces don't leak the base64'd user:pass. Set
  # TUSC_DEBUG_UNSAFE=1 to acknowledge the risk and re-enable -v.
  if [[ $DEBUG ]] && { [[ -z $HAS_AUTH ]] || [[ -n "${TUSC_DEBUG_UNSAFE:-}" ]]; }; then
    cmd+=(-v)
  fi
  # -sS = silent + show errors. For the PATCH (the only large body
  # transfer) we drop -s so curl's progress meter writes to stderr.
  if [[ $is_patch -eq 1 && -z $NOSPIN && -z $DEBUG ]]; then
    cmd+=(-S)
  else
    cmd+=(-sS)
  fi
  cmd+=(-L -D "$HEADER" -H "Tus-Resumable: 1.0.0")
  [[ $HAS_AUTH ]] && cmd+=(--basic --user "$CRED_USER:$CRED_PASS")
  # CURLARGS is a user-supplied passthrough captured as an array from
  # the "--" sentinel during argv parsing. Safe to splat directly.
  [[ ${#CURLARGS[@]} -gt 0 ]] && cmd+=("${CURLARGS[@]}")
  cmd+=("$@")
  # Append %{url_effective} to stdout so we can resolve a relative
  # Location against the post-redirect URL, not the original target.
  # Wrapped in markers so we can pull it back out without confusing
  # it for response body bytes. Goes AFTER CURLARGS so a user-supplied
  # `-- -w ...` doesn't override ours (curl uses the last -w on the
  # command line).
  local URL_MARK="__TUSC_URL_EFFECTIVE_3f4d29__"
  cmd+=(-w "${URL_MARK}%{url_effective}${URL_MARK}")

  if [[ $DEBUG ]]; then
    # Mask the password BEFORE shell-quoting. Doing it after `printf %q`
    # misses passwords with metacharacters (`a b` becomes `a\ b`, etc.)
    # — the raw substring wouldn't match the quoted form.
    local cmd_disp i
    cmd_disp=("${cmd[@]}")
    if [[ $HAS_AUTH ]]; then
      for (( i=0; i < ${#cmd_disp[@]} - 1; i++ )); do
        if [[ "${cmd_disp[i]}" == "--user" ]]; then
          cmd_disp[i+1]="$CRED_USER:***"
          break
        fi
      done
    fi
    debug "> $(printf '%q ' "${cmd_disp[@]}")"
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

  # Pull %{url_effective} (and its markers) back out of BODY.
  EFFECTIVE_URL=""
  if [[ "$BODY" == *"$URL_MARK"*"$URL_MARK"* ]]; then
    EFFECTIVE_URL=${BODY#*$URL_MARK}
    EFFECTIVE_URL=${EFFECTIVE_URL%%$URL_MARK*}
    BODY=${BODY%%$URL_MARK*}
  fi

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
    # Prefer curl's post-redirect URL; fall back to the caller's last
    # positional arg (the URL by convention). Don't use cmd[-1] —
    # that's our internal `-w` value now that it appends last.
    local target="${EFFECTIVE_URL:-$target_url}"
    local msg="✖ Request failed: HTTP ${STATUS:-?} on $target"
    [[ -n "$BODY" ]] && msg="$msg"$'\n'"$BODY"
    error "$msg" 1
  fi
  return $RET
}

# http response header (case-insensitive lookup against the raw header
# file). curl -L writes the headers of *every* response in a redirect
# chain into the dump file. We want the value from the final response
# only — reset state at each `HTTP/...` line so a redirect's
# `Location: <intermediate>` doesn't shadow the final TUS upload URL.
header() # $1 = key
{
  [[ -f "$HEADER" ]] || return 0
  awk -v k="$1" '
    BEGIN { k = tolower(k); val = "" }
    /^HTTP\// { val = ""; next }
    {
      sub(/\r$/, "")
      i = index($0, ":")
      if (i == 0) next
      n = substr($0, 1, i - 1)
      v = substr($0, i + 1)
      sub(/^ +/, "", v)
      if (tolower(n) == k) val = v
    }
    END { print val }
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

# Print the success line + URL inline. Sets REPORTED=1 so on-exit
# doesn't add an "Unfinished upload" hint on top. (See the dir-mode
# block below for why this is inline and not in the EXIT trap.)
report_success()
{
  REPORTED=1
  if [[ $SKIPPED ]]; then
    ok "ℹ Already uploaded — skipping (re-run with --restart to overwrite)."
  else
    ok "✔ Uploaded successfully!"
  fi
  info "URL: $TUSURL"
}

# EXIT trap: clean up tempfiles + print an "interrupted, please
# resume" hint if upload_one didn't get to report_success first.
on-exit()
{
  no-spinner
  rm -f -- "$FILEPART_TMP" "$MANIFEST_TMP" "$HEADER0" "$HEADER" 2>/dev/null
  [[ $REPORTED ]] && return 0
  [[ -z "${OFFSET:-}" ]] && return 0
  # Mid-upload exit without a success report — most likely Ctrl-C or
  # a signal. The pre-trap $OFFSET already reflects whatever
  # upload_one had reached; don't try to re-read from $HEADER (we
  # just deleted it above) — use line() with no exit code so the
  # script's existing exit status survives.
  if [[ $((SIZE - ${OFFSET:-0})) -gt 0 ]]; then
    line "✖ Unfinished upload, please rerun the command to resume." 31 0 "" 2
    [[ -n "${TUSURL:-}" ]] && line "URL: $TUSURL" 33 0 "" 2
  fi
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
    -R | --restart) RESTART=1; shift ;;
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

# Credentials: prefer --creds <file>; fall back to TUSC_USER+TUSC_PASS
# env vars so callers can avoid putting secrets on disk. HAS_AUTH is
# the internal flag the rest of the code checks. Use CRED_USER /
# CRED_PASS internally rather than USER/PASS so we don't authenticate
# as the shell's $USER if a creds file forgot to set its own.
if [[ $CREDS ]]; then
  [[ -f "$CREDS" ]] || error "--creds file '$CREDS' not found" 1
  # Blank USER/PASS first so we can detect a creds file that supplies
  # only one of them — otherwise the shell's ambient $USER would
  # silently stand in for a missing username.
  USER="" PASS=""
  # shellcheck disable=SC1090
  source "$CREDS"
  [[ -n "$USER" && -n "$PASS" ]] \
    || error "--creds file '$CREDS' must set both USER and PASS" 1
  CRED_USER=$USER
  CRED_PASS=$PASS
  HAS_AUTH=1
elif [[ -n "${TUSC_USER:-}" && -n "${TUSC_PASS:-}" ]]; then
  CRED_USER=$TUSC_USER
  CRED_PASS=$TUSC_PASS
  HAS_AUTH=1
fi
# --host is required even for --locate: lookup keys are namespaced by
# host+base-path, so a hostless locate has nothing to look up.
[[ $HOST ]] || error "--host required" 1
[[ $FILE ]] || error "--file required" 1

SUMALGO=${SUMALGO:-sha1}
case "$SUMALGO" in
  sha1|sha224|sha256|sha384|sha512) ;;
  *) error "--algo '$SUMALGO' not supported (use sha1|sha224|sha256|sha384|sha512)" 1 ;;
esac

BASEPATH=${BASEPATH:-/files/}

# Per-file upload body. Success paths call report_success inline;
# the EXIT trap handles cleanup and the interrupted-resume hint.
# See the dir-mode block below for the subshell rationale.
upload_one() # $1 = absolute file path, $2 = name for Upload-Metadata.filename
{
  FILE=$1
  NAME=$2
  # When dir mode invokes us in a subshell we inherit MANIFEST_TMP
  # from the parent. The subshell's EXIT trap would then rm the
  # parent's manifest mid-loop — clear it so only the parent cleans.
  MANIFEST_TMP=""

  [[ -f $FILE ]] || error "--file '$FILE' doesn't exist" 1
  SIZE=$(fsize "$FILE")
  HEADER=$(mktemp -t tus.XXXXXXXXXX)

  # File checksum: skip rehashing if we have it cached for this
  # (path, nanosecond-mtime, size, algo) tuple. Both nanosecond mtime
  # AND size are mixed in so a rewrite that preserves second-mtime
  # *and* size (the rare edge case left after the size-in-key change)
  # still has to match nanoseconds to hit. Set TUSC_NOCACHE=1 to force
  # a fresh checksum every run.
  CKEY="$FILE:$(fmtime_fine "$FILE"):$SIZE"
  if [[ -n "${TUSC_NOCACHE:-}" ]]; then
    KEY=""
  else
    KEY=$(cache-checksum-get "$CKEY" "$SUMALGO")
  fi
  if [[ -z "$KEY" ]]; then
    [[ $DEBUG ]] && debug "> checksum $SUMALGO $FILE"
    spinner
    KEY=$(hash_file_hex "$SUMALGO" "$FILE")
    no-spinner
    cache-checksum-set "$CKEY" "$SUMALGO" "$KEY"
  fi

  # Upload-Key must be unique per (content, full destination). Mix in
  # HOST, BASEPATH, and NAME so host aliases pointing at the same
  # backend (rare but real) don't collide on servers that dedupe
  # globally by Upload-Key. Re-running the same upload at the same
  # full destination still keys identically, so resume works.
  UPLOAD_KEY=$(printf '%s:%s:%s:%s' "$KEY" "$HOST" "$BASEPATH" "$NAME" | hash_stdin_hex "$SUMALGO")

  [[ $DEBUG ]] && info "HOST  : $HOST\nHEADER: $HEADER\nFILE  : $NAME\nSIZE  : $SIZE\nKEY   : $KEY\nUPLOAD_KEY: $UPLOAD_KEY"

  TUSURL=$(cache-loc-get "$HOST$BASEPATH" "$UPLOAD_KEY")

  # --restart needs to (a) ignore the cached URL and (b) send a fresh
  # Upload-Key so a server that dedupes on it creates a new upload
  # instead of handing back the existing one. POST_UPLOAD_KEY carries
  # an extra nonce on restart; the local cache (and resume on later
  # non-restart runs) still keys on the canonical UPLOAD_KEY.
  POST_UPLOAD_KEY=$UPLOAD_KEY
  if [[ $RESTART ]]; then
    TUSURL=""
    POST_UPLOAD_KEY="$UPLOAD_KEY-$(printf '%s%s%s' "$$" "$RANDOM" "$(date +%s%N 2>/dev/null || date +%s)" | hash_stdin_hex sha1 | cut -c1-16)"
  fi

  if [[ $LOCATE ]]; then
    info "URL: $TUSURL"
    REPORTED=1
    [[ -n "$TUSURL" ]] && exit 0 || exit 1
  fi

  # Probe the cached URL. A 404/410 just means the server forgot it —
  # fall through to a fresh POST. `|| true` keeps `set -e` from
  # aborting the script silently on a non-2xx HEAD return.
  [[ -n "$TUSURL" ]] && { request --head "$TUSURL" || true; }

  FILEPART=$FILE
  if [[ -n "$TUSURL" ]] && [[ $ISOK -eq 1 ]]; then
    OFFSET=$(header "Upload-Offset") LEFTOVER=$((SIZE - OFFSET))
    if [[ $LEFTOVER -eq 0 ]]; then
      SKIPPED=1
      report_success
      exit 0
    fi
    if [[ $OFFSET -gt 0 ]]; then
      PCT=$(( OFFSET * 100 / SIZE ))
      info "↻ Resuming at byte $OFFSET / $SIZE (${PCT}%)"
      [[ $DEBUG ]] && debug "> filepart $OFFSET $LEFTOVER $FILE"
      spinner && FILEPART=$(filepart "$OFFSET" "$LEFTOVER" "$FILE") && no-spinner
    fi
  else
    OFFSET=0 LEFTOVER=$SIZE
    META="filename $(printf %s "$NAME" | b64)"
    [[ $HAS_AUTH ]] && META="$META,user $(printf %s "$CRED_USER" | b64)"
    # No Upload-Checksum on the POST: the create request has no body.
    request \
      -H "Upload-Length: $SIZE" \
      -H "Upload-Key: $POST_UPLOAD_KEY" \
      -H "Upload-Metadata: $META" \
      -X POST "$HOST$BASEPATH"

    TUSURL=$(header "Location")
    [[ -n "$TUSURL" ]] || error "POST returned 2xx but no Location header" 1
    # Resolve relative Location against the POST's effective URL
    # (post-redirect), falling back to $HOST$BASEPATH if curl didn't
    # report one.
    TUSURL=$(resolve_url "${EFFECTIVE_URL:-$HOST$BASEPATH}" "$TUSURL")
    cache-loc-set "$HOST$BASEPATH" "$UPLOAD_KEY" "$TUSURL"

    # 0-byte file: POST already finalized the upload. Don't send an
    # empty PATCH — some servers reject it with 404.
    if [[ $SIZE -eq 0 ]]; then
      OFFSET=0
      report_success
      exit 0
    fi
  fi

  # PATCH. `--upload-file` already sets Content-Length; an explicit
  # `Transfer-Encoding: chunked` here is invalid in HTTP/2 (curl emits
  # chunk-framed bytes inside the H2 body, tripping LB 400s).
  #
  # Per the TUS spec Upload-Checksum is for the *current request
  # body*, so we digest FILEPART (the partial slice on resume), not
  # the whole file. Skip if openssl isn't available.
  PATCH_ARGS=(
    -H "Content-Type: application/offset+octet-stream"
    -H "Content-Length: $LEFTOVER"
    -H "Upload-Offset: $OFFSET"
  )
  PATCH_SUM=$(body-checksum-b64 "$SUMALGO" "$FILEPART")
  [[ -n "$PATCH_SUM" ]] && PATCH_ARGS+=(-H "Upload-Checksum: $SUMALGO $PATCH_SUM")
  PATCH_ARGS+=(--upload-file "$FILEPART" --request PATCH "$TUSURL")
  request "${PATCH_ARGS[@]}" || error "Request failed" 1

  # tusd returns the final Upload-Offset in the PATCH 204 response.
  PATCH_OFFSET=$(header "Upload-Offset")
  if [[ "$PATCH_OFFSET" == "$SIZE" ]]; then
    OFFSET=$PATCH_OFFSET
    report_success
    exit 0
  fi

  # Fallback: poll HEAD up to 30 iterations for servers that respond
  # before committing.
  HEADER0=$HEADER; HEADER=$(mktemp -t tus.XXXXXXXXXX)
  for _ in $(seq 1 30); do
    request --head "$TUSURL" > /dev/null || true
    POLL_OFFSET=$(header "Upload-Offset")
    if [[ "$POLL_OFFSET" == "$SIZE" ]]; then
      OFFSET=$POLL_OFFSET
      report_success
      exit 0
    fi
    sleep 2
  done
  error "Upload did not finalize after polling" 1
}

trap on-exit EXIT

# Directory mode: walk the tree and run upload_one per file in an
# explicit subshell. Two bash gotchas drive the unusual call pattern:
#
#   1. The parent's EXIT trap is NOT inherited into a `(...)` subshell,
#      so we re-install it inside the subshell to keep per-file
#      cleanup (rm tempfiles) and the interrupted-upload message.
#   2. `( ... ) || handler` disables `set -e` *inside* the subshell —
#      plain command failures would continue past instead of aborting.
#      We avoid the `||` and capture $? via `set +e` / `set -e` so the
#      subshell runs with `set -e` honored.
#
# CURLARGS, HAS_AUTH, the cred values, and all the helper functions
# are inherited by the subshell — no argv reconstruction needed.
if [[ $DIRMODE ]]; then
  ROOT=$(realpath "$FILE") || error "--file '$FILE' not found" 1
  [[ -d "$ROOT" ]] || error "--file must be a directory when -d/--dir is given" 1
  ROOT="${ROOT%/}"
  ROOT_NAME=$(basename "$ROOT")

  # Single-pass: snapshot the file list into a manifest, count from
  # it, iterate from it. Saves walking the tree twice. Tracked in the
  # global MANIFEST_TMP so the EXIT trap removes it even if the user
  # Ctrl-Cs out of the upload loop.
  ensure-tusdir
  MANIFEST_TMP=$(mktemp "$TUSDIR/manifest.XXXXXXXX")
  find "$ROOT" -type f -print0 | LC_ALL=C sort -z > "$MANIFEST_TMP"
  total=$(tr -dc '\0' < "$MANIFEST_TMP" | wc -c | tr -d ' ')
  [[ $total -eq 0 ]] && error "no files under '$ROOT'" 1
  info "Uploading $total file(s) from $ROOT (as $ROOT_NAME/...)"

  idx=0 fails=0
  while IFS= read -r -d '' f; do
    idx=$((idx+1))
    rel="$ROOT_NAME/${f#$ROOT/}"
    info "[$idx/$total] $rel"
    set +e
    ( set -e; trap on-exit EXIT; upload_one "$f" "$rel" )
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && fails=$((fails+1))
  done < "$MANIFEST_TMP"

  [[ $fails -gt 0 ]] && error "$fails file(s) failed to upload" 1
  ok "✔ $total file(s) uploaded from $ROOT"
  exit 0
fi

upload_one "$FILE" "${NAME_OVERRIDE:-$(basename "$FILE")}"
