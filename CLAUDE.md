# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This directory contains tooling to rip audio CDs to Opus files on Linux/Manjaro, plus the resulting `.opus` files from completed rips.

## Scripts

### `rip.sh` – CD ripping

```bash
./rip.sh [AUSGABEVERZEICHNIS]
```

Rips an audio CD using `abcde` + `cdparanoia` and encodes to Opus 192 kbps. If no output directory is given, files land in the current working directory.

**Flow:**
1. Dependency check (abcde, opusenc, cdparanoia, cd-discid, wget, eject, python3, python-mutagen)
2. CD drive detection (`/dev/cdrom`, `/dev/sr0–2`)
3. MusicBrainz disc ID lookup (pure Python, no extra tools) → pre-fills title/artist
4. Interactive prompts: confirm/override title, choose single-file (`-1`) or per-track mode
5. Writes a temporary `~/.abcde.conf` (backed up and restored on exit via `trap`)
6. Runs `abcde`; in single-file mode sets Ogg Vorbis Comments via `python-mutagen` afterward
7. Prints rip/merge times and output file size

**Single-file mode** skips MusicBrainz inside abcde (`NOCDDBQUERY=y`) and writes TITLE/ALBUM/ARTIST tags with mutagen after the fact.

**Multi-track mode** requires the AUR Perl packages `perl-musicbrainz-discid` and `perl-webservice-musicbrainz` (checked at runtime, only in this mode).

## Key implementation details

- `bereinige_titel()` sanitises titles for Windows-compatible paths: `/`→`-`, `:`→`_`, spaces→`_`, removes `*?"<>|\,&`, strips leading/trailing `._-`, collapses repeated `_`.
- `schreibe_abcde_config()` generates `~/.abcde.conf` at runtime with `MAXPROCS=$(nproc)` and `LOWDISK=n` for parallel rip+encode.
- `$SECONDS` (bash built-in) is used for elapsed-time tracking; output is formatted as `M:SS` / `H:MM:SS`.

## Runtime dependencies

| Tool | Manjaro package |
|---|---|
| abcde | `abcde` |
| opusenc | `opus-tools` |
| cdparanoia | `cdparanoia` |
| cd-discid | `cd-discid` |
| python-mutagen | `python-mutagen` |
| Perl MB modules (multi-track only) | AUR: `perl-musicbrainz-discid perl-webservice-musicbrainz` |
