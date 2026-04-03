> [!NOTE]
> Coded by Claude Code with human testing of the result.

# rip.sh — CD Ripper to Opus

Rips an audio CD to high-quality [Opus](https://opus-codec.org/) files with a single command. Album metadata is fetched automatically from [MusicBrainz](https://musicbrainz.org/) — no typing required for well-known releases. Output filenames are sanitised to be safe on Windows, macOS, and Linux.

Two output modes:

| Mode | Best for | Result |
|---|---|---|
| **Single file** | Audiobooks, audio dramas, live recordings | One `.opus` file, fully tagged |
| **Individual tracks** | Music albums | One `.opus` per track, tagged via MusicBrainz |

Encoding uses all available CPU cores in parallel (via `abcde` + `cdparanoia`), so ripping a typical 70-minute album takes around 8–10 minutes including error correction.

---

## Requirements

Manjaro / Arch Linux. Install all dependencies at once:

```bash
sudo pacman -S abcde opus-tools cdparanoia cd-discid wget eject python python-mutagen
```

For **individual-track mode** only, two additional AUR packages are needed (MusicBrainz track tagging inside abcde):

```bash
pamac install perl-musicbrainz-discid perl-webservice-musicbrainz
# or: yay -S perl-musicbrainz-discid perl-webservice-musicbrainz
```

The script checks all dependencies on startup and prints exact install commands for anything missing.

---

## Usage

```bash
./rip.sh [OUTPUT_DIRECTORY]
```

Insert a CD, run the script, answer three short questions, done.  
`OUTPUT_DIRECTORY` is optional — defaults to the current directory.

---

## Example: audiobook / audio drama (single file)

Insert the CD, then:

```
$ ./rip.sh ~/audiobooks

╔══════════════════════════════════════════╗
║       CD Ripper  →  Opus Encoder         ║
╚══════════════════════════════════════════╝

────────────────────────────────────────────────────────
→ Checking system requirements ...
✓ All required programs are installed.

✓ CD-ROM drive found: /dev/sr0
→ Checking for audio CD in /dev/sr0 ...
✓ Audio CD detected.

────────────────────────────────────────────────────────
Settings:

→ Looking up CD in MusicBrainz database ...

✓ MusicBrainz entry found: Harry Potter and the Philosopher's Stone (Stephen Fry)

  Enter custom title? (leave empty to keep MusicBrainz title): 
→ Title adjusted for filename: Harry_Potter_and_the_Philosophers_Stone

  Combine all tracks into a single Opus file? [y/N]: y
→ Mode: Single file → Harry_Potter_and_the_Philosophers_Stone.opus
→ MusicBrainz skipped during ripping; metadata will be set afterward.
→ Output directory: /home/alice/audiobooks

  Start ripping now? [Y/n]: 
────────────────────────────────────────────────────────
→ Creating abcde configuration (16 CPU cores, Opus 192 kbps) ...
✓ Configuration ready.

────────────────────────────────────────────────────────

Starting CD ripping process ...

  [abcde / cdparanoia output ...]

────────────────────────────────────────────────────────
→ Setting metadata on Harry_Potter_and_the_Philosophers_Stone.opus ...
✓ Metadata set: TITLE=Harry Potter and the Philosopher's Stone, ARTIST=Stephen Fry

────────────────────────────────────────────────────────
✓ Ripping complete!

✓ File saved:  /home/alice/audiobooks/Harry_Potter_and_the_Philosophers_Stone.opus
✓ File size:   143M

  Elapsed time:
    Ripping/encoding:  9:14
    Merging/metadata:  0:01
    Total:             9:47
```

**Result:**

```
~/audiobooks/
└── Harry_Potter_and_the_Philosophers_Stone.opus   (143 MB, TITLE + ARTIST tagged)
```

---

## Example: music album (individual tracks)

```
$ ./rip.sh ~/music

╔══════════════════════════════════════════╗
║       CD Ripper  →  Opus Encoder         ║
╚══════════════════════════════════════════╝

────────────────────────────────────────────────────────
→ Checking system requirements ...
✓ All required programs are installed.

✓ CD-ROM drive found: /dev/sr0
→ Checking for audio CD in /dev/sr0 ...
✓ Audio CD detected.

────────────────────────────────────────────────────────
Settings:

→ Looking up CD in MusicBrainz database ...

✓ MusicBrainz entry found: Abbey Road (The Beatles)

  Enter custom title? (leave empty to keep MusicBrainz title): 
→ Title: Abbey_Road
→ Mode: Individual tracks → folder Abbey_Road/
→ Output directory: /home/alice/music

  Start ripping now? [Y/n]: 

────────────────────────────────────────────────────────
→ Creating abcde configuration (16 CPU cores, Opus 192 kbps) ...
✓ Configuration ready.

────────────────────────────────────────────────────────

Starting CD ripping process ...
Note: Confirm track information interactively if prompted.

  [abcde / cdparanoia output ...]

────────────────────────────────────────────────────────
✓ Ripping complete!

✓ Files saved to: /home/alice/music/Abbey_Road/
✓ 17 Opus file(s), total size: 121M

  Elapsed time:
    Ripping/encoding:  8:03
    Total:             8:36
```

**Result:**

```
~/music/Abbey_Road/
├── 01.Come_Together.opus
├── 02.Something.opus
├── 03.Maxwell's_Silver_Hammer.opus
├── ...
└── 17.Her_Majesty.opus
```

Each file is tagged with track title, artist, album, and track number by abcde via MusicBrainz.

---

## When MusicBrainz doesn't know the CD

For obscure or self-produced CDs, the lookup simply falls back to a manual prompt:

```
⚠ WARNING: No MusicBrainz entry found (no network, unknown CD, or timeout).

  CD title: My Band - Live in Hamburg 2019
→ Title adjusted for filename: My_Band_-_Live_in_Hamburg_2019
```

Everything else works exactly the same.
