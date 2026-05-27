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

FULL=$(readlink -f $0) TUSC=$(basename $0) SPINID=0 CURLARGS=

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
version() { echo v1.1.1; }

# update tusc
update()
{
  NEWVER=`curl -sSL https://raw.githubusercontent.com/adhocore/tusc.sh/master/VERSION`
  [[ "v$NEWVER" == "$(version)" ]] && ok "Already latest version" 0

  info "Updating $TUSC ..."
  curl -sSLo ${FULL} https://raw.githubusercontent.com/adhocore/tusc.sh/master/tusc.sh
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
    $(info "-f --file")      $(comment "The file to upload.")
    $(info "-F --force")     $(comment "Ignore the cached upload URL; start a fresh upload.")
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

# create a part of file (portable: BSD dd has no iflag=skip_bytes)
filepart() # $1 = start_byte, $2 = byte_length (unused; always remainder), $3 = file
{
  tail -c +"$(( $1 + 1 ))" "$3" > "$3.part"
  realpath "$3.part"
}

# http request
request()
{
  echo > $HEADER
  [[ $CREDS ]] && USERPASS="--basic --user '$USER:$PASS' "
  [[ $DEBUG ]] && debug "> curl ${USERPASS//:$PASS/}-sSLD $HEADER -H 'Tus-Resumable: 1.0.0' $1"
  [[ $DEBUG ]] && DBG="-v"

  # Quiet by default (-sS = silent + show errors). For the PATCH — the
  # only large body transfer — drop -s so curl's built-in progress meter
  # writes to stderr.
  local SILENT="-sS"
  local stderr_redir="2>&1"
  if [[ "$1" == *"--request PATCH"* && -z $NOSPIN && -z $DEBUG ]]; then
    SILENT="-S"
    stderr_redir=""   # let curl's progress meter reach the terminal
  fi
  [[ $DEBUG ]] && stderr_redir=""

  BODY=$(bash -c "curl $DBG $USERPASS${SILENT}LD $HEADER -H 'Tus-Resumable: 1.0.0' $CURLARGS $1 $stderr_redir")

  STATUS=$(awk '/^HTTP\// { match($0, /[0-9][0-9][0-9]/); s = substr($0,RSTART,3) } END { print s }' "$HEADER")
  if [[ "$STATUS" == 20* ]]; then ISOK=1 RET=0; else ISOK=0 RET=1; fi
  if [[ $ISOK -eq 0 ]] && [[ "$1" != *"--head"* ]]; then
    local msg="✖ Request failed: HTTP ${STATUS:-?} on $(echo "$1" | awk '{print $NF}')"
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
    OFFSET=$(header "Upload-Offset")  LEFTOVER=$((SIZE - ${OFFSET:-0}))
  fi
  rm -f $FILE.part $HEADER0 $HEADER
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
    -u | --update) update; exit 0 ;;
         --version | version) version; exit 0 ;;
    --) shift; CURLARGS=$@; break ;;
    *) if [[ $HOST ]]; then
        if [[ $FILE ]]; then SUMALGO="${SUMALGO:-$1}"; else FILE="$1"; fi
      else HOST=$1; fi
      shift ;;
  esac
done

trap on-exit EXIT

[[ $CREDS ]] && { [[ -f $CREDS ]] && source $CREDS && [[ $PASS ]] || error "--creds file couldn't be loaded" 1; }
[[ $HOST ]] || [[ $LOCATE ]] || error "--host required" 1
[[ $FILE ]] || error "--file required" 1
[[ -f $FILE ]] || error "--file doesn't exist" 1

SUMALGO=${SUMALGO:-sha1}
[[ $SUMALGO == "sha"* ]] || error "--algo '$SUMALGO' not supported" 1

FILE=`realpath "$FILE"`  NAME=`basename "$FILE"`  SIZE=`fsize "$FILE"`  MTIME=`fmtime "$FILE"`
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
CHKSUM="$SUMALGO $(printf %s "$KEY" | b64)"

[[ $DEBUG ]] && info "HOST  : $HOST\nHEADER: $HEADER\nFILE  : $NAME\nSIZE  : $SIZE\nKEY   : $KEY\nCHKSUM: $CHKSUM"

# head request
BASEPATH=${BASEPATH:-/files/}
TUSURL=$(locate "$HOST" "$BASEPATH" "$KEY")
# --force ignores any cached upload URL so we always start a fresh POST.
[[ $FORCE ]] && TUSURL=""
[[ $LOCATE ]] && info "URL: $TUSURL" && [[ -n "$TUSURL" ]]; [[ $LOCATE ]] && exit $?
# Probe the cached URL with a HEAD. A non-2xx here just means the
# server forgot the upload (tusd's retention expired, host cleaned up,
# etc.) — fall through to a fresh POST. `|| true` keeps `set -e` from
# aborting the script silently on the HEAD's non-zero return.
[[ -n "$TUSURL" ]] && { request "--head $TUSURL" || true; }

FILEPART=$FILE
if [[ -n "$TUSURL" ]] && [[ $ISOK -eq 1 ]]; then
  OFFSET=$(header "Upload-Offset") LEFTOVER=$((SIZE - OFFSET))
  # Server reports this upload is already complete — short-circuit and
  # tell the user it was a no-op (re-run with --force to upload again).
  [[ $LEFTOVER -eq 0 ]] && SKIPPED=1 && exit 0
  [[ $OFFSET -gt 0 && $DEBUG ]] && debug "> filepart $OFFSET $LEFTOVER $FILE"
  [[ $OFFSET -gt 0 ]] && spinner && FILEPART=`filepart $OFFSET $LEFTOVER $FILE` && no-spinner

# create request
else
  OFFSET=0 LEFTOVER=$SIZE
  META="filename $(printf %s "$NAME" | b64)"
  [[ $CREDS ]] && META="$META,user $(printf %s "$USER" | b64)"
  request "-H 'Upload-Length: $SIZE' \
    -H 'Upload-Key: $KEY' \
    -H 'Upload-Checksum: $CHKSUM' \
    -H 'Upload-Metadata: $META' \
    -X POST $HOST$BASEPATH"

  # save location config
  TUSURL=$(header "Location")
  [[ $TUSURL ]] && cache-loc-set "$HOST$BASEPATH" "$KEY" "$TUSURL"
fi

# curl's built-in progress meter does the job for the PATCH (visible in
# request() unless -S/--no-spin or DEBUG=1 is set), so don't start the
# bash spinner here.

# patch request — `--upload-file` already sets Content-Length from the
# file size; an explicit `Transfer-Encoding: chunked` here is invalid
# over HTTP/2 (e.g. behind an AWS ELB) and makes curl send chunk-framed
# bytes inside the H2 body, tripping a 400 at the load balancer.
request "-H 'Content-Type: application/offset+octet-stream' \
  -H 'Content-Length: $LEFTOVER' \
  -H 'Upload-Checksum: $CHKSUM' \
  -H 'Upload-Offset: $OFFSET' \
  --upload-file '$FILEPART' \
  --request PATCH '$TUSURL'" || error "Request failed" 1

HEADER0=$HEADER HEADER=`mktemp -t tus.XXXXXXXXXX`
while :; do
  [[ $(header "Upload-Offset") -eq $SIZE ]] && exit
  request "--head $TUSURL" > /dev/null
  [[ $(header "Upload-Offset") -eq $SIZE ]] || sleep 2
done
