# adhocore/tusc.sh

[![Latest Version](https://img.shields.io/github/release/adhocore/tusc.sh.svg?style=flat-square)](https://github.com/adhocore/tusc.sh/releases)
[![Test](https://github.com/adhocore/tusc.sh/actions/workflows/test.yml/badge.svg)](https://github.com/adhocore/tusc.sh/actions/workflows/test.yml)
[![Software License](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat-square)](LICENSE)
[![Tweet](https://img.shields.io/twitter/url/http/shields.io.svg?style=social)](https://twitter.com/intent/tweet?text=Resumable+large+file+uploads+via+TUS+client+protocol+implemented+in+bash&url=https://github.com/adhocore/tusc.sh&hashtags=bash,tus,resumable,uploads)
[![Support](https://img.shields.io/static/v1?label=Support&message=%E2%9D%A4&logo=GitHub)](https://github.com/sponsors/adhocore)
<!-- [![Donate 15](https://img.shields.io/badge/donate-paypal-blue.svg?style=flat-square&label=donate+15)](https://www.paypal.me/ji10/15usd)
[![Donate 25](https://img.shields.io/badge/donate-paypal-blue.svg?style=flat-square&label=donate+25)](https://www.paypal.me/ji10/25usd)
[![Donate 50](https://img.shields.io/badge/donate-paypal-blue.svg?style=flat-square&label=donate+50)](https://www.paypal.me/ji10/50usd) -->


`tusc` is [tus 1.0.0](https://tus.io) client protocol implementation for bash.

`tusc` lets you upload big files to servers supporting tus protocol right from your terminal.

If anything goes wrong, you can rerun the command to resume upload from where it was left off.

> **Fun Fact**: Git LFS also supports tus.io protocol.

## Installation

```sh
curl -sSLo ~/tusc https://raw.githubusercontent.com/adhocore/tusc.sh/main/tusc.sh
# for global binary
chmod +x ~/tusc && sudo ln -s ~/tusc /usr/local/bin/tusc
# OR, for user binary
chmod +x ~/tusc && mv ~/tusc ~/.local/bin/tusc
```

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

Resume state lives at `$TMPDIR/tusc.<uid>/` (override with the `TUSDIR`
env var). It's keyed by sha1 of the file path + mtime so renaming or
touching the file forces a re-hash, and one file per cache entry means
nothing to parse or corrupt.


## Usage and Examples
```
  tusc v0.5.0 | (c) Jitendra Adhikari
  tusc is bash implementation of tus-client (https://tus.io).

  Usage:
    tusc <--options> -- [curl args]
    tusc <host> <file> [algo] -- [curl args]

  Options:
    -a --algo      The algorigthm for key &/or checksum.
                   (Eg: sha1, sha256)
    -b --base-path The tus-server base path (Default: '/files/').
    -c --creds     File with credentials; user and pass in shell syntax:
                     USER="my_user"
                     PASS="my_pass"
    -C --no-color  Donot color the output (Useful for parsing output).
    -f --file      The file to upload.
    -h --help      Show help information and usage.
    -H --host      The tus-server host where file is uploaded.
    -L --locate    Locate the uploaded file in tus-server.
    -S --no-spin   Donot show the spinner (Useful for parsing output).
    -u --update    Update tusc to latest version.
       --version   Print the current tusc version.

  Examples:
    tusc --help                           # shows this help
    tusc --update                         # updates itself
    tusc --version                        # prints current version of itself
    tusc    0:1080    ww.mp4              # uploads ww.mp4 to http://0.0.0.0:1080/files/
    tusc -H 0:1080 -f ww.mp4              # same as above
    tusc -H 0:1080 -f ww.mp4 -- -Lv       # same as above plus sends -Lv to curl command
    tusc -H 0:1080 -f ww.mp4 -a sha256    # same as above but uses sha256 algo for key/checksum
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
