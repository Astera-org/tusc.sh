# Astera-org/tusc.sh

[![Test](https://github.com/Astera-org/tusc.sh/actions/workflows/test.yml/badge.svg)](https://github.com/Astera-org/tusc.sh/actions/workflows/test.yml)
[![Software License](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat-square)](LICENSE)

This is the [Astera Institute](https://astera.org) fork of
[`adhocore/tusc.sh`](https://github.com/adhocore/tusc.sh) with macOS /
`bash` 3.2 portability, no `jq` dependency, progress / resume
visibility, directory upload, and a Lima-based Linux test harness.
Upstream's original copyright is preserved in [`LICENSE`](LICENSE).

`tusc` is [tus 1.0.0](https://tus.io) client protocol implementation for bash.

`tusc` lets you upload big files to servers supporting tus protocol right from your terminal.

If anything goes wrong, you can rerun the command to resume upload from where it was left off.

> **Fun Fact**: Git LFS also supports tus.io protocol.

## Installation

```sh
curl -fsSLo ~/tusc https://raw.githubusercontent.com/Astera-org/tusc.sh/main/tusc.sh
# for global binary
chmod +x ~/tusc && sudo ln -s ~/tusc /usr/local/bin/tusc
# OR, for user binary
chmod +x ~/tusc && mv ~/tusc ~/.local/bin/tusc
```

`tusc --update` will pull the latest `tusc.sh` from this same fork.

This fork runs on stock macOS using the system `/bin/bash` (3.2) — no
Homebrew bash, no GNU coreutils, no `jq` required.

### System Requirements

- `bash` ≥ 3.2 (macOS stock bash is fine)
- `awk`
- `base64`
- `curl`
- `grep`, `tr`
- `mktemp`
- `realpath` (macOS 12.3+ ships it in `/usr/bin`; Linux ships it in `coreutils`)
- `shasum` (macOS) **or** `sha1sum`/`sha256sum` (Linux)
- `stat`, `tail`, `seq`, `sleep`

> Donot worry, in a typical UNIX flavored system these are likely to be there already.

### Resume-state cache

`tusc.sh` keeps a small per-user cache so that interrupting an upload
(Ctrl-C, network drop, server restart) and re-running the same command
**resumes from where it left off** instead of starting over. Two kinds
of entries get stored:

| File                                          | Holds                                  | Why                                      |
| --------------------------------------------- | -------------------------------------- | ---------------------------------------- |
| `ck.<sha1-of-path:mtime>.<algo>`              | The file's sha1/sha256/… hex digest    | Skip re-hashing multi-GB files each run  |
| `loc.<checksum>.<sha1-of-host+base-path>`     | The TUS upload URL returned by `POST`  | Lets the next run `HEAD` it and resume   |

Touching or rewriting the file changes its mtime, which invalidates
the checksum entry — so the cache never serves stale hashes.

**Location**

Default: `${TMPDIR:-/tmp}/tusc.<uid>/` — under the OS temp dir, mode
`0700`, scoped per Unix uid. Survives across invocations within a
session; the OS will reclaim it on reboot/cleanup.

Override with the `TUSDIR` environment variable:

```sh
# Cache that survives reboots
TUSDIR=~/.cache/tusc ./tusc.sh -H ... -f ...

# Fully isolated, single-run cache
TUSDIR=$(mktemp -d) ./tusc.sh -H ... -f ...
```

**When to wipe it**

```sh
rm -rf "${TMPDIR:-/tmp}/tusc.$(id -u)"
```

- the file changed but mtime didn't (unusual — touch the file instead),
- you want to force a brand-new TUS upload rather than resuming an
  existing one,
- you suspect the cached resume URL points at an upload the server has
  since deleted (in that case `tusc.sh` will detect the `404` on `HEAD`
  and POST a new upload anyway, so this is mostly defensive).


## Usage and Examples
```
  tusc.sh v2.0.0 | (c) Jitendra Adhikari | https://github.com/adhocore
  tusc.sh is bash implementation of tus-client (https://tus.io).
  With contributions from Astera Institute (https://astera.org).

  Usage:
    tusc.sh <--options>
    tusc.sh <host> <file> [algo]

  Options:
    -a --algo      The algorigthm for key &/or checksum.
                   (Eg: sha1, sha256)
    -b --base-path The tus-server base path (Default: '/files/').
    -c --creds     File with credentials; user and pass in shell syntax:
                     USER="my_user"
                     PASS="my_pass"
    -C --no-color  Donot color the output (Useful for parsing output).
    -f --file      The file to upload (or directory, with -d).
    -F --force     Ignore the cached upload URL; start a fresh upload.
    -N --name      Override the filename sent in Upload-Metadata.
                   (May contain slashes; server gets the literal value.)
    -d --dir       Treat --file as a directory; upload every file under it,
                   preserving the relative path in Upload-Metadata.filename.
    -h --help      Show help information and usage.
    -H --host      The tus-server host where file is uploaded.
    -L --locate    Locate the uploaded file in tus-server.
    -S --no-spin   Donot show the spinner (Useful for parsing output).
    -u --update    Update tusc to latest version.
       --version   Print the current tusc version.

  Environment:
    DEBUG=1        Verbose curl + show debug headers on stderr.
    TUSDIR         Cache dir for resume state and file checksums.
                   (Default: $TMPDIR/tusc.<uid>/. Delete to force a fresh upload.)

  Examples:
    tusc.sh --help                           # shows this help
    tusc.sh --update                         # updates itself
    tusc.sh --version                        # prints current version of itself
    tusc.sh    0:1080    ww.mp4              # uploads ww.mp4 to http://0.0.0.0:1080/files/
    tusc.sh -H 0:1080 -f ww.mp4              # same as above
    tusc.sh -H 0:1080 -f ww.mp4 -a sha256    # same as above but uses sha256 algo for key/checksum
    tusc.sh -H 0:1080 -f ww.mp4 -b /store/   # uploads ww.mp4 to http://0.0.0.0:1080/store/
```

If you want to parse the output of `tusc`, pass in `-C` (no color) and `-S` (no spin) flags. Eg:
```sh
# Locate the URL of a file and download it
wget $(tusc -H 0:1080 -f ww.mp4 -L -S -C | cut -c 6-999) -O ww.mp4.1
```

### Authentication

If your tusd server requires special header or token for auth, just pass in `[curl args]`:
```sh
tusc -H 0:1080 -f ww.mp4 -b /store/ -- -H "'Authorization: Bearer <token>'" -H "'x-key: value'"
```

In fact you can pass in anything after `--` as extra curl parameter.

### Preview
See `tusc` in action with debug mode where the upload is aborted frequently with `Ctrl+C` interrupt.

[![Screen Preview](https://imgur.com/SN4lE3o.gif "tusc in action")](https://github.com/adhocore/tusc.sh)

### Debugging
To print the debugging information pass in `DEBUG=1` env like so:
```sh
DEBUG=1 tusc 0:1080 ww.mp4
```

To print the lines of script as they are executed, create a debug file:
```sh
touch ~/.tus.dbg
```

To revert the above step, just remove the debug file:
```sh
rm ~/.tus.dbg
```


## Trying Out
To get hands on in local machine, you can install [tusd](https://github.com/tus/tusd#download-pre-builts-binaries-recommended) server.

Then,
```sh
# run tusd server (http://0.0.0.0:1080)
tusd -dir ~/.tusd-data > /dev/null 2>&1 &
# start uploading large files
DEBUG=1 tusc --host 0:1080 --file /full/path/to/large/file

# for tusd v2 (http://0.0.0.0:8080)
tusd -upload-dir ~/.tusd-data > /dev/null 2>&1 &
DEBUG=1 tusc --host 0:8080 --file /full/path/to/large/file
```

While upload is in progress, you can force abort it using `Ctrl+C`.

> Then resume upload again:
```sh
DEBUG=1 tusc --host 0:1080 --file /full/path/to/large/file
```

It should start from where it last stopped.

> You can check the uploaded files like so:
```sh
ls -al ~/.tusd-data
```


## Testing

End-to-end tests live in `test/`. The runner downloads a `tusd`
binary into `test/.cache/` (override with `TUSC_CACHE_DIR=...`),
uploads a 5 MiB fixture, fetches it back, and compares SHA-256s.

### Locally (macOS or Linux)

```sh
bash test/test.sh
```

### Linux from a macOS host, via Lima

[Lima](https://github.com/lima-vm/lima) (`brew install lima`) spins up
an Ubuntu 24.04 VM, installs `curl`/`tar`, mounts the repo read-only at
`/repo`, and runs the test inside the VM.

```sh
bash test/run-lima.sh            # leave the VM running for repeat runs
bash test/run-lima.sh --clean    # tear the VM down when done
```

The same `test/test.sh` runs in GitHub Actions on both
`ubuntu-latest` and `macos-latest`.

### Contributors

- [adhocore](https://github.com/adhocore) - **Lead Developer**
- [tonk](https://github.com/tonk) - **Credential support**
- Wouter van Hilst - **Chunked upload**
- [Astera Institute](https://astera.org) - **macOS / bash 3.2 portability, removal of `jq` dependency, Lima-based test harness**

### Tooling

The macOS portability work, `jq` removal, and Lima-based test harness
in this fork were drafted with the help of
[Claude Code](https://claude.com/claude-code) (Anthropic) and reviewed
by a human before landing.

## License

Released under the [MIT License](LICENSE). Original work © 2018
Jitendra Adhikari; fork changes © 2026 Astera Institute. The original
copyright notice is preserved in `LICENSE` as required.
