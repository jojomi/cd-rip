# homerip TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `homerip/`, a Rust TUI that guides the user through ripping Hörspiel CDs (Bibi und Tina, Sternenfohlen, Horse Club), shelling out to the existing `rip.sh`/`upload.sh` for the actual rip/upload work, with its own fast MusicBrainz TOC lookup for naming and dedup.

**Architecture:** Cargo binary crate at `homerip/`. Pure, unit-tested logic modules (sanitize, series config, filename/tag builders, TOC/disc-id, dependency check) feed a thin `ratatui`+`crossterm` wizard UI in `main.rs`. Actual ripping/uploading is done by spawning `rip.sh`/`upload.sh` as subprocesses with the terminal handed over (raw mode off, inherited stdio) so abcde/cdparanoia/rsync output shows normally.

**Tech Stack:** Rust (cargo 1.95), `ratatui`, `crossterm`, `serde`+`serde_derive`, `toml`, `regex`, `anyhow`, `sha1`, `base64`, `ureq` (MusicBrainz HTTP), `which`.

## Global Constraints

- Project lives at `homerip/` in the repo root (sibling of `rip.sh`).
- Rip/upload technique itself is never reimplemented in Rust — always shell out to `rip.sh` / `upload.sh`.
- Canonical filename: `{file_prefix}_Folge_{NNN}_{sanitized_subtitle}.opus`. Canonical tag title: `{display_name}, Folge {N}: {subtitle}`.
- Series list and their naming rules live in `homerip/series.toml`, not hardcoded — must support Bibi und Tina, Sternenfohlen, Horse Club out of the box.
- Rip target directory defaults to the existing `Ripping/` directory (repo root, one level above `homerip/`).
- Dedup check is local-filesystem only (per spec — no remote/SSH check).

---

### Task 1: Cargo project scaffold

**Files:**
- Create: `homerip/Cargo.toml`
- Create: `homerip/src/main.rs`
- Create: `homerip/.gitignore`

**Interfaces:**
- Produces: a compiling `homerip` binary crate that later tasks add modules to via `mod` declarations in `main.rs`.

- [ ] **Step 1: Create the crate**

```bash
cd /run/storage/encrypted/data/audio/Ripping
cargo new homerip --name homerip
```

- [ ] **Step 2: Set dependencies**

Replace `homerip/Cargo.toml` with:

```toml
[package]
name = "homerip"
version = "0.1.0"
edition = "2021"

[dependencies]
ratatui = "0.29"
crossterm = "0.28"
serde = { version = "1", features = ["derive"] }
toml = "0.8"
regex = "1"
anyhow = "1"
sha1 = "0.10"
base64 = "0.22"
ureq = "2"
which = "7"
```

- [ ] **Step 3: Verify it builds**

```bash
cd homerip && cargo build
```

Expected: `Compiling homerip ...` then `Finished` (this will download and compile all dependencies — may take a minute).

- [ ] **Step 4: Commit**

```bash
git add homerip/Cargo.toml homerip/Cargo.lock homerip/src/main.rs homerip/.gitignore
git commit -m "Scaffold homerip Rust TUI project"
```

---

### Task 2: sanitize_title port

**Files:**
- Create: `homerip/src/sanitize.rs`
- Modify: `homerip/src/main.rs` (add `mod sanitize;`)

**Interfaces:**
- Produces: `pub fn sanitize_title(input: &str) -> String` — used by Task 4 (filename builder) and Task 6 (episode matching output cleanup).

- [ ] **Step 1: Write the failing tests**

Create `homerip/src/sanitize.rs`:

```rust
pub fn sanitize_title(input: &str) -> String {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::sanitize_title;

    #[test]
    fn replaces_slash_and_colon() {
        assert_eq!(sanitize_title("A/B:C"), "A-B_C");
    }

    #[test]
    fn collapses_whitespace_to_underscore() {
        assert_eq!(sanitize_title("Hello   World"), "Hello_World");
    }

    #[test]
    fn strips_forbidden_characters() {
        assert_eq!(sanitize_title("Wer, was & wie? \"Test\" <ok> |x|"), "Wer_was_wie_Test_ok_x");
    }

    #[test]
    fn strips_leading_trailing_dots_underscores_dashes() {
        assert_eq!(sanitize_title("_-.Title.-_"), "Title");
    }

    #[test]
    fn collapses_repeated_underscores() {
        assert_eq!(sanitize_title("A___B"), "A_B");
    }

    #[test]
    fn real_world_bibi_title() {
        assert_eq!(
            sanitize_title("Wölfe in der Puszta"),
            "Wölfe_in_der_Puszta"
        );
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test sanitize
```

Expected: compile error or panic from `todo!()`.

- [ ] **Step 3: Implement `sanitize_title`**

Replace the `todo!()` function in `homerip/src/sanitize.rs` with:

```rust
use regex::Regex;

pub fn sanitize_title(input: &str) -> String {
    let step1 = input.replace('/', "-").replace(':', "_");

    let ws_re = Regex::new(r"\s+").unwrap();
    let step2 = ws_re.replace_all(&step1, "_").to_string();

    let step3: String = step2
        .chars()
        .filter(|c| !"*?\"<>|\\,&".contains(*c))
        .collect();

    let trimmed = step3
        .trim_start_matches(|c| "._-".contains(c))
        .trim_end_matches(|c| "._-".contains(c));

    let us_re = Regex::new(r"_+").unwrap();
    us_re.replace_all(trimmed, "_").to_string()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test sanitize
```

Expected: `test result: ok. 6 passed`.

- [ ] **Step 5: Wire the module and commit**

Add near the top of `homerip/src/main.rs`:

```rust
mod sanitize;
```

```bash
git add homerip/src/sanitize.rs homerip/src/main.rs
git commit -m "Add sanitize_title port with tests"
```

---

### Task 3: Series config (series.toml)

**Files:**
- Create: `homerip/src/series.rs`
- Create: `homerip/series.toml`
- Modify: `homerip/src/main.rs` (add `mod series;`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `pub struct Series { pub key: String, pub display_name: String, pub file_prefix: String, pub title_regex: String, pub artist: String }` and `pub fn load_series(path: &std::path::Path) -> anyhow::Result<Vec<Series>>`. Task 4 consumes `Series.title_regex`, `Series.file_prefix`, `Series.display_name`, `Series.artist`.

- [ ] **Step 1: Write the failing test**

Create `homerip/src/series.rs`:

```rust
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct Series {
    pub key: String,
    pub display_name: String,
    pub file_prefix: String,
    pub title_regex: String,
    #[serde(default)]
    pub artist: String,
}

#[derive(Debug, Deserialize)]
struct SeriesFile {
    series: Vec<Series>,
}

pub fn load_series(path: &Path) -> anyhow::Result<Vec<Series>> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn loads_three_default_series() {
        let dir = std::env::temp_dir();
        let path = dir.join("homerip_test_series.toml");
        let mut f = std::fs::File::create(&path).unwrap();
        write!(
            f,
            r#"
[[series]]
key = "bibi_und_tina"
display_name = "Bibi & Tina"
file_prefix = "Bibi_und_Tina"
title_regex = "Bibi\\s*[&und]+\\s*Tina,\\s*Folge\\s+(\\d+):\\s*(.+)"
artist = "Elfie Donnelly"

[[series]]
key = "horse_club"
display_name = "Horse Club"
file_prefix = "Horse_Club"
title_regex = "Horse\\s*Club,?\\s*Folge\\s+(\\d+):?\\s*(.+)"
artist = ""
"#
        )
        .unwrap();

        let series = load_series(&path).unwrap();
        assert_eq!(series.len(), 2);
        assert_eq!(series[0].key, "bibi_und_tina");
        assert_eq!(series[0].artist, "Elfie Donnelly");
        assert_eq!(series[1].artist, "");

        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn missing_file_is_error() {
        let path = std::path::Path::new("/nonexistent/homerip_series.toml");
        assert!(load_series(path).is_err());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test series
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `load_series`**

Replace `todo!()` with:

```rust
pub fn load_series(path: &Path) -> anyhow::Result<Vec<Series>> {
    let content = std::fs::read_to_string(path)?;
    let parsed: SeriesFile = toml::from_str(&content)?;
    Ok(parsed.series)
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test series
```

Expected: `test result: ok. 2 passed`.

- [ ] **Step 5: Create the real default `homerip/series.toml`**

```toml
[[series]]
key = "bibi_und_tina"
display_name = "Bibi & Tina"
file_prefix = "Bibi_und_Tina"
title_regex = "Bibi\\s*[&und]+\\s*Tina,\\s*Folge\\s+(\\d+):\\s*(.+)"
artist = "Elfie Donnelly"

[[series]]
key = "sternenfohlen"
display_name = "Sternenfohlen"
file_prefix = "Sternenfohlen"
title_regex = "Sternenfohlen,?\\s*Folge\\s+(\\d+):?\\s*(.+)"
artist = ""

[[series]]
key = "horse_club"
display_name = "Horse Club"
file_prefix = "Horse_Club"
title_regex = "Horse\\s*Club,?\\s*Folge\\s+(\\d+):?\\s*(.+)"
artist = ""
```

- [ ] **Step 6: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod series;
```

```bash
git add homerip/src/series.rs homerip/series.toml homerip/src/main.rs
git commit -m "Add series.toml config and loader"
```

---

### Task 4: Episode matching + canonical filename/tag builders

**Files:**
- Create: `homerip/src/naming.rs`
- Modify: `homerip/src/main.rs` (add `mod naming;`)

**Interfaces:**
- Consumes: `series::Series` (Task 3), `sanitize::sanitize_title` (Task 2).
- Produces: `pub struct Episode { pub number: u32, pub subtitle: String }`, `pub fn match_episode(series: &series::Series, mb_title: &str) -> Option<Episode>`, `pub fn canonical_filename(series: &series::Series, episode: &Episode) -> String`, `pub fn canonical_tag_title(series: &series::Series, episode: &Episode) -> String`. Task 5 (dedup) consumes `canonical_filename`. Task 11 (rename/retag) consumes both builders.

- [ ] **Step 1: Write the failing tests**

Create `homerip/src/naming.rs`:

```rust
use crate::series::Series;
use regex::Regex;

#[derive(Debug, Clone, PartialEq)]
pub struct Episode {
    pub number: u32,
    pub subtitle: String,
}

pub fn match_episode(series: &Series, mb_title: &str) -> Option<Episode> {
    todo!()
}

pub fn canonical_filename(series: &Series, episode: &Episode) -> String {
    todo!()
}

pub fn canonical_tag_title(series: &Series, episode: &Episode) -> String {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bibi_series() -> Series {
        Series {
            key: "bibi_und_tina".into(),
            display_name: "Bibi & Tina".into(),
            file_prefix: "Bibi_und_Tina".into(),
            title_regex: r"Bibi\s*[&und]+\s*Tina,\s*Folge\s+(\d+):\s*(.+)".into(),
            artist: "Elfie Donnelly".into(),
        }
    }

    #[test]
    fn matches_bibi_title() {
        let series = bibi_series();
        let ep = match_episode(&series, "Bibi & Tina, Folge 60: Wölfe in der Puszta").unwrap();
        assert_eq!(ep.number, 60);
        assert_eq!(ep.subtitle, "Wölfe in der Puszta");
    }

    #[test]
    fn no_match_returns_none() {
        let series = bibi_series();
        assert!(match_episode(&series, "Some Unrelated Album Title").is_none());
    }

    #[test]
    fn builds_canonical_filename() {
        let series = bibi_series();
        let ep = Episode { number: 60, subtitle: "Wölfe in der Puszta".into() };
        assert_eq!(
            canonical_filename(&series, &ep),
            "Bibi_und_Tina_Folge_060_Wölfe_in_der_Puszta.opus"
        );
    }

    #[test]
    fn builds_canonical_tag_title() {
        let series = bibi_series();
        let ep = Episode { number: 60, subtitle: "Wölfe in der Puszta".into() };
        assert_eq!(
            canonical_tag_title(&series, &ep),
            "Bibi & Tina, Folge 60: Wölfe in der Puszta"
        );
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test naming
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement the three functions**

Replace the `todo!()` bodies:

```rust
pub fn match_episode(series: &Series, mb_title: &str) -> Option<Episode> {
    let re = Regex::new(&series.title_regex).ok()?;
    let caps = re.captures(mb_title)?;
    let number: u32 = caps.get(1)?.as_str().parse().ok()?;
    let subtitle = caps.get(2)?.as_str().trim().to_string();
    Some(Episode { number, subtitle })
}

pub fn canonical_filename(series: &Series, episode: &Episode) -> String {
    let safe_subtitle = crate::sanitize::sanitize_title(&episode.subtitle);
    format!(
        "{}_Folge_{:03}_{}.opus",
        series.file_prefix, episode.number, safe_subtitle
    )
}

pub fn canonical_tag_title(series: &Series, episode: &Episode) -> String {
    format!(
        "{}, Folge {}: {}",
        series.display_name, episode.number, episode.subtitle
    )
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test naming
```

Expected: `test result: ok. 4 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod naming;
```

```bash
git add homerip/src/naming.rs homerip/src/main.rs
git commit -m "Add episode matching and canonical filename/tag builders"
```

---

### Task 5: Dedup check

**Files:**
- Create: `homerip/src/dedup.rs`
- Modify: `homerip/src/main.rs` (add `mod dedup;`)

**Interfaces:**
- Consumes: nothing (takes a directory path and filename string, e.g. from Task 4's `canonical_filename`).
- Produces: `pub fn already_ripped(dir: &std::path::Path, filename: &str) -> bool`. Consumed by `main.rs` wizard flow (Task 15).

- [ ] **Step 1: Write the failing test**

Create `homerip/src/dedup.rs`:

```rust
use std::path::Path;

pub fn already_ripped(dir: &Path, filename: &str) -> bool {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_existing_file() {
        let dir = std::env::temp_dir().join("homerip_dedup_test");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("Bibi_und_Tina_Folge_060_Test.opus");
        std::fs::write(&file, b"data").unwrap();

        assert!(already_ripped(&dir, "Bibi_und_Tina_Folge_060_Test.opus"));
        assert!(!already_ripped(&dir, "Bibi_und_Tina_Folge_061_Other.opus"));

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd homerip && cargo test dedup
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `already_ripped`**

```rust
pub fn already_ripped(dir: &Path, filename: &str) -> bool {
    dir.join(filename).is_file()
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd homerip && cargo test dedup
```

Expected: `test result: ok. 1 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod dedup;
```

```bash
git add homerip/src/dedup.rs homerip/src/main.rs
git commit -m "Add local dedup check"
```

---

### Task 6: TOC parsing + MusicBrainz disc-ID

**Files:**
- Create: `homerip/src/discid.rs`
- Modify: `homerip/src/main.rs` (add `mod discid;`)

**Interfaces:**
- Consumes: nothing (pure parsing of `cdparanoia -Q` text output).
- Produces: `pub struct TocEntry { pub track: u32, pub length: u32, pub begin: u32 }`, `pub fn parse_toc(text: &str) -> anyhow::Result<Vec<TocEntry>>`, `pub fn compute_disc_id(entries: &[TocEntry]) -> String`. Consumed by Task 7 (MusicBrainz client) and Task 15 (wizard flow).

- [ ] **Step 1: Write the failing tests**

Create `homerip/src/discid.rs`. This ports the TOC regex and disc-ID hash from `rip.sh`'s `get_mb_info()` (SHA-1 over first/last track, leadout, and up to 99 track offsets, base64-encoded with `+`→`.`, `/`→`_`, `=`→`-`).

```rust
use anyhow::{anyhow, Result};
use base64::Engine;
use regex::Regex;
use sha1::{Digest, Sha1};

#[derive(Debug, Clone, PartialEq)]
pub struct TocEntry {
    pub track: u32,
    pub length: u32,
    pub begin: u32,
}

pub fn parse_toc(text: &str) -> Result<Vec<TocEntry>> {
    todo!()
}

pub fn compute_disc_id(entries: &[TocEntry]) -> String {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_TOC: &str = "\
CDROM model sensed sensed: FAKE DRIVE
  1.    17640 [03:55.15]        0 [00:00.00]    no   no  2
  2.    15000 [03:20.00]    17640 [03:55.15]    no   no  2
";

    #[test]
    fn parses_two_tracks() {
        let entries = parse_toc(SAMPLE_TOC).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0], TocEntry { track: 1, length: 17640, begin: 0 });
        assert_eq!(entries[1], TocEntry { track: 2, length: 15000, begin: 17640 });
    }

    #[test]
    fn empty_text_is_error() {
        assert!(parse_toc("no tracks here").is_err());
    }

    #[test]
    fn disc_id_is_deterministic_and_stable_length() {
        let entries = parse_toc(SAMPLE_TOC).unwrap();
        let id = compute_disc_id(&entries);
        // MusicBrainz disc IDs are always 28 characters
        assert_eq!(id.len(), 28);
        // Same input must give the same ID every time
        assert_eq!(id, compute_disc_id(&entries));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test discid
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `parse_toc` and `compute_disc_id`**

```rust
pub fn parse_toc(text: &str) -> Result<Vec<TocEntry>> {
    let re = Regex::new(r"(?m)^\s+(\d+)\.\s+(\d+)\s+\[[\d:.]+\]\s+(\d+)\s+").unwrap();
    let entries: Vec<TocEntry> = re
        .captures_iter(text)
        .map(|c| TocEntry {
            track: c[1].parse().unwrap(),
            length: c[2].parse().unwrap(),
            begin: c[3].parse().unwrap(),
        })
        .collect();

    if entries.is_empty() {
        return Err(anyhow!("no tracks found in TOC output"));
    }
    Ok(entries)
}

pub fn compute_disc_id(entries: &[TocEntry]) -> String {
    let first_track = entries[0].track;
    let last_track = entries[entries.len() - 1].track;
    let last = &entries[entries.len() - 1];
    let leadout = last.begin + last.length + 150;

    let mut data = format!("{:02X}{:02X}{:08X}", first_track, last_track, leadout);
    for i in 0..99 {
        let offset = entries.get(i).map(|e| e.begin + 150).unwrap_or(0);
        data.push_str(&format!("{:08X}", offset));
    }

    let digest = Sha1::digest(data.as_bytes());
    let b64 = base64::engine::general_purpose::STANDARD.encode(digest);
    b64.replace('+', ".").replace('/', "_").replace('=', "-")
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test discid
```

Expected: `test result: ok. 3 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod discid;
```

```bash
git add homerip/src/discid.rs homerip/src/main.rs
git commit -m "Add TOC parsing and MusicBrainz disc-ID calculation"
```

---

### Task 7: MusicBrainz client (trait + HTTP impl + fixture impl)

**Files:**
- Create: `homerip/src/musicbrainz.rs`
- Modify: `homerip/src/main.rs` (add `mod musicbrainz;`)

**Interfaces:**
- Consumes: disc ID string (from Task 6's `compute_disc_id`).
- Produces: `pub struct ReleaseInfo { pub title: String, pub artist: String }`, `pub trait MusicBrainzClient { fn lookup_disc(&self, disc_id: &str) -> anyhow::Result<Option<ReleaseInfo>>; }`, `pub struct HttpMusicBrainzClient;` (real impl), `pub struct FixtureMusicBrainzClient { pub response: Option<ReleaseInfo> }` (test/mock impl). Consumed by `main.rs` wizard flow (Task 15).

- [ ] **Step 1: Write the failing test**

Create `homerip/src/musicbrainz.rs`:

```rust
use anyhow::Result;

#[derive(Debug, Clone, PartialEq)]
pub struct ReleaseInfo {
    pub title: String,
    pub artist: String,
}

pub trait MusicBrainzClient {
    fn lookup_disc(&self, disc_id: &str) -> Result<Option<ReleaseInfo>>;
}

pub struct HttpMusicBrainzClient;

impl MusicBrainzClient for HttpMusicBrainzClient {
    fn lookup_disc(&self, disc_id: &str) -> Result<Option<ReleaseInfo>> {
        todo!()
    }
}

/// Test/offline double: always returns the configured response.
pub struct FixtureMusicBrainzClient {
    pub response: Option<ReleaseInfo>,
}

impl MusicBrainzClient for FixtureMusicBrainzClient {
    fn lookup_disc(&self, _disc_id: &str) -> Result<Option<ReleaseInfo>> {
        Ok(self.response.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_client_returns_configured_release() {
        let client = FixtureMusicBrainzClient {
            response: Some(ReleaseInfo {
                title: "Bibi & Tina, Folge 60: Wölfe in der Puszta".into(),
                artist: "Elfie Donnelly".into(),
            }),
        };
        let result = client.lookup_disc("anything").unwrap().unwrap();
        assert_eq!(result.title, "Bibi & Tina, Folge 60: Wölfe in der Puszta");
    }

    #[test]
    fn fixture_client_returns_none_when_unset() {
        let client = FixtureMusicBrainzClient { response: None };
        assert!(client.lookup_disc("anything").unwrap().is_none());
    }
}
```

- [ ] **Step 2: Run tests to verify they pass for the fixture (HTTP impl is not exercised by tests)**

```bash
cd homerip && cargo test musicbrainz
```

Expected: `test result: ok. 2 passed` — the fixture tests pass immediately since `FixtureMusicBrainzClient` has no `todo!()`. `HttpMusicBrainzClient` still has `todo!()` but is untested here (it needs live network access, see Step 3 rationale).

- [ ] **Step 3: Implement `HttpMusicBrainzClient`**

Replace the `todo!()` body:

```rust
impl MusicBrainzClient for HttpMusicBrainzClient {
    fn lookup_disc(&self, disc_id: &str) -> Result<Option<ReleaseInfo>> {
        let url = format!(
            "https://musicbrainz.org/ws/2/discid/{disc_id}?fmt=json&inc=artist-credits"
        );
        let response = ureq::get(&url)
            .set("User-Agent", "homerip/1.0 (linux cd ripper)")
            .call();

        let response = match response {
            Ok(r) => r,
            Err(_) => return Ok(None),
        };

        let json: serde_json::Value = response.into_json()?;
        let releases = json.get("releases").and_then(|r| r.as_array());
        let Some(releases) = releases else { return Ok(None) };
        let Some(release) = releases.first() else { return Ok(None) };

        let title = release
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();

        let mut artist = String::new();
        if let Some(credits) = release.get("artist-credit").and_then(|c| c.as_array()) {
            for credit in credits {
                if let Some(name) = credit.get("name").and_then(|n| n.as_str()) {
                    artist.push_str(name);
                }
                if let Some(join) = credit.get("joinphrase").and_then(|j| j.as_str()) {
                    artist.push_str(join);
                }
            }
        }

        if title.is_empty() {
            Ok(None)
        } else {
            Ok(Some(ReleaseInfo { title, artist: artist.trim().to_string() }))
        }
    }
}
```

Add `serde_json = "1"` to `homerip/Cargo.toml` under `[dependencies]`.

- [ ] **Step 4: Verify everything still builds and tests pass**

```bash
cd homerip && cargo build && cargo test musicbrainz
```

Expected: builds cleanly, `test result: ok. 2 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod musicbrainz;
```

```bash
git add homerip/src/musicbrainz.rs homerip/src/main.rs homerip/Cargo.toml homerip/Cargo.lock
git commit -m "Add MusicBrainz client trait with HTTP and fixture implementations"
```

---

### Task 8: CD drive detection + dependency check

**Files:**
- Create: `homerip/src/system_check.rs`
- Modify: `homerip/src/main.rs` (add `mod system_check;`)

**Interfaces:**
- Consumes: nothing.
- Produces: `pub fn find_drive() -> anyhow::Result<std::path::PathBuf>`, `pub fn check_medium(device: &std::path::Path) -> anyhow::Result<()>`, `pub fn missing_dependencies(tools: &[&str], exists: impl Fn(&str) -> bool) -> Vec<String>` (pure, testable), `pub fn check_all_dependencies() -> Vec<String>` (thin wrapper using `which::which`). Consumed by `main.rs` (Task 15) at startup and before drive detection.

- [ ] **Step 1: Write the failing test**

Create `homerip/src/system_check.rs`:

```rust
use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

const DRIVE_CANDIDATES: &[&str] = &["/dev/cdrom", "/dev/sr0", "/dev/sr1", "/dev/sr2"];
const REQUIRED_TOOLS: &[&str] = &["abcde", "cdparanoia", "cd-discid", "rsync", "python3"];

pub fn find_drive() -> Result<PathBuf> {
    for candidate in DRIVE_CANDIDATES {
        let path = Path::new(candidate);
        if path.exists() {
            return Ok(path.to_path_buf());
        }
    }
    Err(anyhow!(
        "No CD-ROM drive found. Checked: {}",
        DRIVE_CANDIDATES.join(", ")
    ))
}

pub fn check_medium(device: &Path) -> Result<()> {
    let status = Command::new("cd-discid").arg(device).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("No audio CD found in {}", device.display()))
    }
}

/// Pure so it can be unit-tested without touching the real PATH.
pub fn missing_dependencies(tools: &[&str], exists: impl Fn(&str) -> bool) -> Vec<String> {
    todo!()
}

pub fn check_all_dependencies() -> Vec<String> {
    missing_dependencies(REQUIRED_TOOLS, |tool| which::which(tool).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_missing_tools_only() {
        let tools = ["abcde", "cdparanoia", "rsync"];
        let missing = missing_dependencies(&tools, |t| t != "cdparanoia");
        assert_eq!(missing, vec!["cdparanoia".to_string()]);
    }

    #[test]
    fn empty_when_all_present() {
        let tools = ["abcde", "cdparanoia"];
        let missing = missing_dependencies(&tools, |_| true);
        assert!(missing.is_empty());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test system_check
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `missing_dependencies`**

```rust
pub fn missing_dependencies(tools: &[&str], exists: impl Fn(&str) -> bool) -> Vec<String> {
    tools
        .iter()
        .filter(|t| !exists(t))
        .map(|t| t.to_string())
        .collect()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test system_check
```

Expected: `test result: ok. 2 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod system_check;
```

```bash
git add homerip/src/system_check.rs homerip/src/main.rs
git commit -m "Add CD drive detection and dependency check"
```

Note: `find_drive` and `check_medium` require real hardware and are not unit-tested — verify manually in Task 15's smoke test.

---

### Task 9: Rip subprocess (terminal handoff to rip.sh)

**Files:**
- Create: `homerip/src/rip_process.rs`
- Modify: `homerip/src/main.rs` (add `mod rip_process;`)

**Interfaces:**
- Consumes: nothing new (plain strings/paths).
- Produces: `pub fn run_rip_sh(repo_root: &std::path::Path, output_dir: &std::path::Path, title: &str, artist: &str) -> anyhow::Result<std::process::ExitStatus>`. Consumed by `main.rs` wizard flow (Task 15).

- [ ] **Step 1: Implement (no unit test — this spawns a real interactive subprocess and cannot be meaningfully unit-tested; verified manually in Task 15)**

Create `homerip/src/rip_process.rs`:

```rust
use anyhow::Result;
use std::path::Path;
use std::process::{Command, ExitStatus};

/// Runs rip.sh with the terminal handed over: raw mode must already be
/// disabled and the alternate screen left by the caller before this runs,
/// so abcde/cdparanoia can print to the real terminal.
pub fn run_rip_sh(
    repo_root: &Path,
    output_dir: &Path,
    title: &str,
    artist: &str,
) -> Result<ExitStatus> {
    let script = repo_root.join("rip.sh");
    let status = Command::new(&script)
        .arg("--title")
        .arg(title)
        .arg("--artist")
        .arg(artist)
        .arg("--single")
        .arg("--yes")
        .arg(output_dir)
        .status()?;
    Ok(status)
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd homerip && cargo build
```

Expected: `Finished` with no errors.

- [ ] **Step 3: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod rip_process;
```

```bash
git add homerip/src/rip_process.rs homerip/src/main.rs
git commit -m "Add rip.sh subprocess wrapper"
```

---

### Task 10: Rename + retag subprocess

**Files:**
- Create: `homerip/src/tagging.rs`
- Modify: `homerip/src/main.rs` (add `mod tagging;`)

**Interfaces:**
- Consumes: `naming::canonical_filename` / `naming::canonical_tag_title` output (Task 4) as plain strings, `sanitize::sanitize_title` (Task 2) indirectly via rip.sh's own filename.
- Produces: `pub fn rename_and_tag(dir: &std::path::Path, raw_filename: &str, canonical_filename: &str, tag_title: &str, artist: &str) -> anyhow::Result<()>`. Consumed by `main.rs` (Task 15).

- [ ] **Step 1: Write the failing test (only the pure rename part is testable without mutagen)**

Create `homerip/src/tagging.rs`:

```rust
use anyhow::{anyhow, Context, Result};
use std::path::Path;
use std::process::Command;

/// Renames the file rip.sh produced to the canonical name, then rewrites
/// TITLE/ALBUM (and ARTIST/ALBUMARTIST if artist is non-empty) via a
/// python3 + mutagen heredoc, matching fix-title.sh's approach.
pub fn rename_and_tag(
    dir: &Path,
    raw_filename: &str,
    canonical_filename: &str,
    tag_title: &str,
    artist: &str,
) -> Result<()> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_when_raw_file_missing() {
        let dir = std::env::temp_dir().join("homerip_tagging_test_missing");
        std::fs::create_dir_all(&dir).unwrap();
        let result = rename_and_tag(&dir, "does_not_exist.opus", "canonical.opus", "Title", "");
        assert!(result.is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn renames_file_on_disk() {
        let dir = std::env::temp_dir().join("homerip_tagging_test_rename");
        std::fs::create_dir_all(&dir).unwrap();
        let raw = dir.join("raw.opus");
        std::fs::write(&raw, b"not a real opus file").unwrap();

        // Tagging via mutagen will fail on this fake file, but the rename
        // must happen before the tagging step runs, so the renamed file
        // must exist on disk regardless of the tagging outcome.
        let _ = rename_and_tag(&dir, "raw.opus", "canonical.opus", "Title", "");
        assert!(dir.join("canonical.opus").is_file());
        assert!(!dir.join("raw.opus").exists());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test tagging
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `rename_and_tag`**

```rust
pub fn rename_and_tag(
    dir: &Path,
    raw_filename: &str,
    canonical_filename: &str,
    tag_title: &str,
    artist: &str,
) -> Result<()> {
    let raw_path = dir.join(raw_filename);
    let canonical_path = dir.join(canonical_filename);

    if !raw_path.is_file() {
        return Err(anyhow!("expected rip.sh output not found: {}", raw_path.display()));
    }

    std::fs::rename(&raw_path, &canonical_path)
        .with_context(|| format!("renaming {} to {}", raw_path.display(), canonical_path.display()))?;

    let script = r#"
import sys
from mutagen.oggopus import OggOpus

file, title, artist = sys.argv[1], sys.argv[2], sys.argv[3]
audio = OggOpus(file)
audio["TITLE"] = [title]
audio["ALBUM"] = [title]
if artist:
    audio["ARTIST"] = [artist]
    audio["ALBUMARTIST"] = [artist]
audio.save()
"#;

    let status = Command::new("python3")
        .arg("-c")
        .arg(script)
        .arg(&canonical_path)
        .arg(tag_title)
        .arg(artist)
        .status()
        .context("running python3 to set tags")?;

    if !status.success() {
        return Err(anyhow!("python3/mutagen tagging failed for {}", canonical_path.display()));
    }

    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test tagging
```

Expected: `test result: ok. 2 passed` (the rename assertions pass even though tagging itself fails on the fake file — the function still returns, and the test only checks the rename side effect).

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod tagging;
```

```bash
git add homerip/src/tagging.rs homerip/src/main.rs
git commit -m "Add rename+retag step after ripping"
```

---

### Task 11: Upload subprocess

**Files:**
- Create: `homerip/src/upload_process.rs`
- Modify: `homerip/src/main.rs` (add `mod upload_process;`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `pub fn run_upload_sh(repo_root: &std::path::Path) -> anyhow::Result<std::process::ExitStatus>`. Consumed by `main.rs` (Task 15).

- [ ] **Step 1: Implement (no unit test — spawns a real subprocess that talks to the network; verified manually in Task 15)**

Create `homerip/src/upload_process.rs`:

```rust
use anyhow::Result;
use std::path::Path;
use std::process::{Command, ExitStatus};

pub fn run_upload_sh(repo_root: &Path) -> Result<ExitStatus> {
    let script = repo_root.join("upload.sh");
    let status = Command::new(&script).current_dir(repo_root).status()?;
    Ok(status)
}
```

- [ ] **Step 2: Verify it builds**

```bash
cd homerip && cargo build
```

Expected: `Finished` with no errors.

- [ ] **Step 3: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod upload_process;
```

```bash
git add homerip/src/upload_process.rs homerip/src/main.rs
git commit -m "Add upload.sh subprocess wrapper"
```

---

### Task 12: upload.sh — add Sternenfohlen line

**Files:**
- Modify: `upload.sh:5-10`

**Interfaces:**
- None (shell script, no Rust interface).

- [ ] **Step 1: Add the Sternenfohlen rsync line**

Current `upload.sh`:

```bash
REMOTE="slzm:/storage/containers/up.slzm.de/data/hoerspiele/"

rsync --ignore-missing-args --ignore-existing --progress Bibi_und_Tina_*.opus "${REMOTE}/Bibi und Tina/"
rsync --ignore-missing-args --ignore-existing --progress Willi_wills_wissen_*.opus "${REMOTE}/"
rsync --ignore-missing-args --ignore-existing --progress Horse_Club_*.opus "${REMOTE}/"
rsync --ignore-missing-args --ignore-existing --progress Ponyhof_Liliengrün_*.opus "${REMOTE}/"
```

Add this line after the `Horse_Club_*.opus` line:

```bash
rsync --ignore-missing-args --ignore-existing --progress Sternenfohlen_*.opus "${REMOTE}/Sternenfohlen/"
```

- [ ] **Step 2: Verify the script is still syntactically valid**

```bash
bash -n upload.sh
```

Expected: no output (exit code 0).

- [ ] **Step 3: Commit**

```bash
git add upload.sh
git commit -m "Add Sternenfohlen upload target"
```

---

### Task 13: Wizard state machine (pure transition logic)

**Files:**
- Create: `homerip/src/wizard.rs`
- Modify: `homerip/src/main.rs` (add `mod wizard;`)

**Interfaces:**
- Consumes: `series::Series` (Task 3), `naming::Episode` (Task 4).
- Produces: `pub enum Screen { SeriesSelect, DriveCheck, Lookup, ManualEntry, Confirm, DedupPrompt, Ripping, Renaming, UploadPrompt, Uploading, Done, Error(String) }`, `pub struct WizardState { pub screen: Screen, pub series: Option<series::Series>, pub episode: Option<naming::Episode>, pub mb_title: Option<String>, pub mb_artist: Option<String>, pub canonical_filename: Option<String> }`, `pub enum WizardEvent { SeriesChosen(series::Series), DriveOk, DriveFailed(String), LookupSucceeded(String, String), LookupFailed, ManualEntrySubmitted(u32, String), DuplicateFound, NoDuplicate, ConfirmAccepted, ConfirmCancelled, RipSucceeded, RipFailed(String), RenameDone, UploadAccepted, UploadDeclined, UploadSucceeded, UploadFailed(String), RestartRequested }`, `pub fn transition(state: WizardState, event: WizardEvent) -> WizardState`. Consumed by `main.rs` event loop (Task 15).

- [ ] **Step 1: Write the failing tests**

Create `homerip/src/wizard.rs`:

```rust
use crate::naming::Episode;
use crate::series::Series;

#[derive(Debug, Clone, PartialEq)]
pub enum Screen {
    SeriesSelect,
    DriveCheck,
    Lookup,
    ManualEntry,
    Confirm,
    DedupPrompt,
    Ripping,
    Renaming,
    UploadPrompt,
    Uploading,
    Done,
    Error(String),
}

#[derive(Debug, Clone, Default)]
pub struct WizardState {
    pub screen_stack: Vec<Screen>,
    pub series: Option<Series>,
    pub episode: Option<Episode>,
    pub mb_title: Option<String>,
    pub mb_artist: Option<String>,
    pub canonical_filename: Option<String>,
}

impl WizardState {
    pub fn new() -> Self {
        WizardState { screen_stack: vec![Screen::SeriesSelect], ..Default::default() }
    }

    pub fn screen(&self) -> &Screen {
        self.screen_stack.last().expect("screen stack is never empty")
    }
}

pub enum WizardEvent {
    SeriesChosen(Series),
    DriveOk,
    DriveFailed(String),
    LookupSucceeded(String, String),
    LookupFailed,
    ManualEntrySubmitted(u32, String),
    DuplicateFound,
    NoDuplicate,
    ConfirmAccepted,
    ConfirmCancelled,
    RipSucceeded,
    RipFailed(String),
    RenameDone,
    UploadAccepted,
    UploadDeclined,
    UploadSucceeded,
    UploadFailed(String),
    RestartRequested,
}

pub fn transition(state: WizardState, event: WizardEvent) -> WizardState {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn series() -> Series {
        Series {
            key: "bibi_und_tina".into(),
            display_name: "Bibi & Tina".into(),
            file_prefix: "Bibi_und_Tina".into(),
            title_regex: ".*".into(),
            artist: "Elfie Donnelly".into(),
        }
    }

    #[test]
    fn series_chosen_moves_to_drive_check() {
        let state = WizardState::new();
        let state = transition(state, WizardEvent::SeriesChosen(series()));
        assert_eq!(*state.screen(), Screen::DriveCheck);
        assert!(state.series.is_some());
    }

    #[test]
    fn drive_failed_moves_to_error() {
        let state = WizardState::new();
        let state = transition(state, WizardEvent::DriveFailed("no drive".into()));
        assert_eq!(*state.screen(), Screen::Error("no drive".into()));
    }

    #[test]
    fn lookup_failed_falls_back_to_manual_entry() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Lookup);
        let state = transition(state, WizardEvent::LookupFailed);
        assert_eq!(*state.screen(), Screen::ManualEntry);
    }

    #[test]
    fn duplicate_found_moves_to_dedup_prompt() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Lookup);
        let state = transition(state, WizardEvent::DuplicateFound);
        assert_eq!(*state.screen(), Screen::DedupPrompt);
    }

    #[test]
    fn no_duplicate_moves_to_confirm() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Lookup);
        let state = transition(state, WizardEvent::NoDuplicate);
        assert_eq!(*state.screen(), Screen::Confirm);
    }

    #[test]
    fn confirm_accepted_moves_to_ripping() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Confirm);
        let state = transition(state, WizardEvent::ConfirmAccepted);
        assert_eq!(*state.screen(), Screen::Ripping);
    }

    #[test]
    fn rip_failed_moves_to_error() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Ripping);
        let state = transition(state, WizardEvent::RipFailed("abcde exit 1".into()));
        assert_eq!(*state.screen(), Screen::Error("abcde exit 1".into()));
    }

    #[test]
    fn rip_succeeded_moves_to_renaming_then_upload_prompt() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Ripping);
        let state = transition(state, WizardEvent::RipSucceeded);
        assert_eq!(*state.screen(), Screen::Renaming);
        let state = transition(state, WizardEvent::RenameDone);
        assert_eq!(*state.screen(), Screen::UploadPrompt);
    }

    #[test]
    fn upload_declined_moves_to_done() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::UploadPrompt);
        let state = transition(state, WizardEvent::UploadDeclined);
        assert_eq!(*state.screen(), Screen::Done);
    }

    #[test]
    fn restart_requested_from_done_returns_to_series_select() {
        let mut state = WizardState::new();
        state.screen_stack.push(Screen::Done);
        let state = transition(state, WizardEvent::RestartRequested);
        assert_eq!(*state.screen(), Screen::SeriesSelect);
        assert!(state.series.is_none());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd homerip && cargo test wizard
```

Expected: panic from `todo!()`.

- [ ] **Step 3: Implement `transition`**

```rust
pub fn transition(mut state: WizardState, event: WizardEvent) -> WizardState {
    match event {
        WizardEvent::SeriesChosen(series) => {
            state.series = Some(series);
            state.screen_stack.push(Screen::DriveCheck);
        }
        WizardEvent::DriveOk => {
            state.screen_stack.push(Screen::Lookup);
        }
        WizardEvent::DriveFailed(msg) => {
            state.screen_stack.push(Screen::Error(msg));
        }
        WizardEvent::LookupSucceeded(title, artist) => {
            state.mb_title = Some(title);
            state.mb_artist = Some(artist);
        }
        WizardEvent::LookupFailed => {
            state.screen_stack.push(Screen::ManualEntry);
        }
        WizardEvent::ManualEntrySubmitted(number, subtitle) => {
            state.episode = Some(Episode { number, subtitle });
        }
        WizardEvent::DuplicateFound => {
            state.screen_stack.push(Screen::DedupPrompt);
        }
        WizardEvent::NoDuplicate => {
            state.screen_stack.push(Screen::Confirm);
        }
        WizardEvent::ConfirmAccepted => {
            state.screen_stack.push(Screen::Ripping);
        }
        WizardEvent::ConfirmCancelled => {
            state = WizardState::new();
        }
        WizardEvent::RipSucceeded => {
            state.screen_stack.push(Screen::Renaming);
        }
        WizardEvent::RipFailed(msg) => {
            state.screen_stack.push(Screen::Error(msg));
        }
        WizardEvent::RenameDone => {
            state.screen_stack.push(Screen::UploadPrompt);
        }
        WizardEvent::UploadAccepted => {
            state.screen_stack.push(Screen::Uploading);
        }
        WizardEvent::UploadDeclined => {
            state.screen_stack.push(Screen::Done);
        }
        WizardEvent::UploadSucceeded => {
            state.screen_stack.push(Screen::Done);
        }
        WizardEvent::UploadFailed(msg) => {
            state.screen_stack.push(Screen::Error(msg));
        }
        WizardEvent::RestartRequested => {
            state = WizardState::new();
        }
    }
    state
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd homerip && cargo test wizard
```

Expected: `test result: ok. 10 passed`.

- [ ] **Step 5: Wire the module and commit**

Add to `homerip/src/main.rs`:

```rust
mod wizard;
```

```bash
git add homerip/src/wizard.rs homerip/src/main.rs
git commit -m "Add wizard state machine with transition tests"
```

---

### Task 14: main.rs — wire everything into a running TUI

**Files:**
- Modify: `homerip/src/main.rs` (full rewrite of `main()` and rendering)

**Interfaces:**
- Consumes: all modules from Tasks 2–13 (`sanitize`, `series`, `naming`, `dedup`, `discid`, `musicbrainz`, `system_check`, `rip_process`, `tagging`, `upload_process`, `wizard`).
- Produces: the runnable `homerip` binary. Nothing else depends on this — it is the final integration point.

- [ ] **Step 1: Replace `homerip/src/main.rs` with the full wizard loop**

```rust
mod dedup;
mod discid;
mod musicbrainz;
mod naming;
mod rip_process;
mod sanitize;
mod series;
mod system_check;
mod tagging;
mod upload_process;
mod wizard;

use anyhow::{Context, Result};
use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use musicbrainz::{HttpMusicBrainzClient, MusicBrainzClient};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Style},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Terminal,
};
use std::io::stdout;
use std::path::{Path, PathBuf};
use std::process::Command;
use wizard::{Screen, WizardEvent, WizardState};

fn repo_root() -> Result<PathBuf> {
    let exe = std::env::current_exe()?;
    // homerip/target/debug/homerip -> repo root is 3 levels up
    Ok(exe
        .parent().context("no parent")?
        .parent().context("no parent")?
        .parent().context("no parent")?
        .parent().context("no parent")?
        .to_path_buf())
}

fn series_toml_path(repo: &Path) -> PathBuf {
    repo.join("homerip").join("series.toml")
}

fn output_dir(repo: &Path) -> PathBuf {
    repo.to_path_buf()
}

fn main() -> Result<()> {
    let repo = repo_root().unwrap_or_else(|_| PathBuf::from("."));

    let missing = system_check::check_all_dependencies();
    if !missing.is_empty() {
        eprintln!("Fehlende Programme: {}", missing.join(", "));
        std::process::exit(1);
    }

    let series_list = series::load_series(&series_toml_path(&repo))
        .context("loading homerip/series.toml")?;

    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(out);
    let mut terminal = Terminal::new(backend)?;

    let mut state = WizardState::new();
    let mut selected_index: usize = 0;

    loop {
        terminal.draw(|f| {
            let area = f.area();
            let block = Block::default().borders(Borders::ALL).title("homerip");

            match state.screen() {
                Screen::SeriesSelect => {
                    let items: Vec<ListItem> = series_list
                        .iter()
                        .map(|s| ListItem::new(s.display_name.clone()))
                        .collect();
                    let list = List::new(items)
                        .block(block)
                        .highlight_style(Style::default().fg(Color::Yellow));
                    f.render_widget(list, area);
                }
                Screen::Error(msg) => {
                    let p = Paragraph::new(format!("Fehler: {msg}\n\n[q] Beenden  [r] Neustart"))
                        .block(block);
                    f.render_widget(p, area);
                }
                Screen::Done => {
                    let p = Paragraph::new("Fertig!\n\n[n] Nächste CD  [q] Beenden").block(block);
                    f.render_widget(p, area);
                }
                other => {
                    let p = Paragraph::new(format!("{other:?}")).block(block);
                    f.render_widget(p, area);
                }
            }
        })?;

        if let Event::Key(key) = event::read()? {
            match state.screen() {
                Screen::SeriesSelect => match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Down => {
                        selected_index = (selected_index + 1).min(series_list.len() - 1);
                    }
                    KeyCode::Up => {
                        selected_index = selected_index.saturating_sub(1);
                    }
                    KeyCode::Enter => {
                        let chosen = series_list[selected_index].clone();
                        state = wizard::transition(state, WizardEvent::SeriesChosen(chosen));

                        match system_check::find_drive() {
                            Ok(device) => match system_check::check_medium(&device) {
                                Ok(()) => {
                                    state = wizard::transition(state, WizardEvent::DriveOk);
                                    run_lookup_and_advance(&mut state, &repo);
                                }
                                Err(e) => {
                                    state = wizard::transition(
                                        state,
                                        WizardEvent::DriveFailed(e.to_string()),
                                    );
                                }
                            },
                            Err(e) => {
                                state = wizard::transition(
                                    state,
                                    WizardEvent::DriveFailed(e.to_string()),
                                );
                            }
                        }
                    }
                    _ => {}
                },
                Screen::Confirm => match key.code {
                    KeyCode::Char('y') => {
                        state = wizard::transition(state, WizardEvent::ConfirmAccepted);
                        run_rip_rename(&mut state, &repo, &output_dir(&repo));
                    }
                    KeyCode::Char('n') => {
                        state = wizard::transition(state, WizardEvent::ConfirmCancelled);
                    }
                    _ => {}
                },
                Screen::DedupPrompt => match key.code {
                    KeyCode::Char('s') => {
                        state = WizardState::new();
                    }
                    KeyCode::Char('f') => {
                        state = wizard::transition(state, WizardEvent::NoDuplicate);
                    }
                    KeyCode::Char('a') => {
                        state = WizardState::new();
                    }
                    _ => {}
                },
                Screen::UploadPrompt => match key.code {
                    KeyCode::Char('y') => {
                        let ok = run_upload(&repo, &mut terminal)?;
                        state = wizard::transition(
                            state,
                            if ok {
                                WizardEvent::UploadSucceeded
                            } else {
                                WizardEvent::UploadFailed("upload.sh fehlgeschlagen".into())
                            },
                        );
                    }
                    KeyCode::Char('n') => {
                        state = wizard::transition(state, WizardEvent::UploadDeclined);
                    }
                    _ => {}
                },
                Screen::Done | Screen::Error(_) => match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char('n') | KeyCode::Char('r') => {
                        state = wizard::transition(state, WizardEvent::RestartRequested);
                        selected_index = 0;
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}

/// Runs the fast TOC + MusicBrainz lookup, matches it against the chosen
/// series, and advances the wizard state accordingly (manual entry,
/// dedup prompt, or confirm screen).
fn run_lookup_and_advance(state: &mut WizardState, repo: &Path) {
    let device = match system_check::find_drive() {
        Ok(d) => d,
        Err(e) => {
            *state = wizard::transition(state.clone(), WizardEvent::DriveFailed(e.to_string()));
            return;
        }
    };

    let toc_output = Command::new("cdparanoia")
        .arg("-Q")
        .arg("-d")
        .arg(&device)
        .output();

    let toc_text = match toc_output {
        Ok(o) => String::from_utf8_lossy(&o.stderr).to_string() + &String::from_utf8_lossy(&o.stdout),
        Err(_) => String::new(),
    };

    let entries = discid::parse_toc(&toc_text).ok();
    let client = HttpMusicBrainzClient;

    let release = entries
        .as_ref()
        .and_then(|e| {
            let id = discid::compute_disc_id(e);
            client.lookup_disc(&id).ok().flatten()
        });

    match release {
        Some(r) => {
            *state = wizard::transition(
                state.clone(),
                WizardEvent::LookupSucceeded(r.title.clone(), r.artist.clone()),
            );
            let series = state.series.clone().expect("series set before lookup");
            match naming::match_episode(&series, &r.title) {
                Some(episode) => {
                    let filename = naming::canonical_filename(&series, &episode);
                    state.episode = Some(episode);
                    state.canonical_filename = Some(filename.clone());
                    if dedup::already_ripped(repo, &filename) {
                        *state = wizard::transition(state.clone(), WizardEvent::DuplicateFound);
                    } else {
                        *state = wizard::transition(state.clone(), WizardEvent::NoDuplicate);
                    }
                }
                None => {
                    *state = wizard::transition(state.clone(), WizardEvent::LookupFailed);
                }
            }
        }
        None => {
            *state = wizard::transition(state.clone(), WizardEvent::LookupFailed);
        }
    }
}

/// Hands the terminal to rip.sh, then to the rename/retag step.
fn run_rip_rename(state: &mut WizardState, repo: &Path, out_dir: &Path) {
    let series = state.series.clone().expect("series set");
    let episode = state.episode.clone().expect("episode set");
    let mb_title = state.mb_title.clone().unwrap_or_default();
    let artist = state.mb_artist.clone().unwrap_or_else(|| series.artist.clone());

    let _ = disable_raw_mode();
    let _ = execute!(stdout(), LeaveAlternateScreen);

    let rip_result = rip_process::run_rip_sh(repo, out_dir, &mb_title, &artist);

    let _ = enable_raw_mode();
    let _ = execute!(stdout(), EnterAlternateScreen);

    match rip_result {
        Ok(status) if status.success() => {
            *state = wizard::transition(state.clone(), WizardEvent::RipSucceeded);
            let raw_filename = format!("{}.opus", sanitize::sanitize_title(&mb_title));
            let canonical = naming::canonical_filename(&series, &episode);
            let tag_title = naming::canonical_tag_title(&series, &episode);
            match tagging::rename_and_tag(out_dir, &raw_filename, &canonical, &tag_title, &artist) {
                Ok(()) => {
                    *state = wizard::transition(state.clone(), WizardEvent::RenameDone);
                }
                Err(e) => {
                    *state = wizard::transition(state.clone(), WizardEvent::RipFailed(e.to_string()));
                }
            }
        }
        Ok(status) => {
            *state = wizard::transition(
                state.clone(),
                WizardEvent::RipFailed(format!("rip.sh exited with {status}")),
            );
        }
        Err(e) => {
            *state = wizard::transition(state.clone(), WizardEvent::RipFailed(e.to_string()));
        }
    }
}

fn run_upload(
    repo: &Path,
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
) -> Result<bool> {
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;

    let status = upload_process::run_upload_sh(repo);

    enable_raw_mode()?;
    execute!(terminal.backend_mut(), EnterAlternateScreen)?;

    Ok(status.map(|s| s.success()).unwrap_or(false))
}
```

- [ ] **Step 2: Build**

```bash
cd homerip && cargo build
```

Expected: `Finished`. Fix any borrow-checker errors that come up (this file is large and glues many modules together — expect at least one or two rounds of small fixes, e.g. cloning `state` before passing it into `wizard::transition` by value).

- [ ] **Step 3: Run the full test suite**

```bash
cd homerip && cargo test
```

Expected: all tests from Tasks 2–13 still pass (`test result: ok.` for each module).

- [ ] **Step 4: Manual smoke test**

```bash
cd homerip && cargo run
```

Expected: TUI opens showing "Bibi & Tina", "Sternenfohlen", "Horse Club" in a list. Navigate with arrow keys, press `q` to quit cleanly (terminal restored, no leftover alternate screen). Note in the PR/commit description that CD-drive-dependent steps (drive detection, ripping, MusicBrainz lookup, upload) need a real CD and network access to test end-to-end, per the spec's Testing section.

- [ ] **Step 5: Commit**

```bash
git add homerip/src/main.rs
git commit -m "Wire homerip wizard into a runnable TUI"
```

---

### Task 15: README for homerip

**Files:**
- Create: `homerip/README.md`

**Interfaces:**
- None.

- [ ] **Step 1: Write usage docs**

```markdown
# homerip

TUI wizard for ripping Hörspiel CDs (Bibi & Tina, Sternenfohlen, Horse Club) that
shells out to the existing `rip.sh` / `upload.sh` in the repo root for the actual
ripping and uploading, and does its own fast MusicBrainz disc-ID lookup to know
the episode title/number before ripping (so it can skip CDs already ripped).

## Usage

```bash
cd homerip
cargo run
```

Requires: `abcde`, `cdparanoia`, `cd-discid`, `rsync`, `python3` + `python-mutagen`
(same as `rip.sh`) — checked at startup, with install hints printed if missing.

## Adding a series

Add a block to `homerip/series.toml`:

```toml
[[series]]
key = "my_series"
display_name = "My Series"
file_prefix = "My_Series"
title_regex = "My\\s*Series,?\\s*Folge\\s+(\\d+):?\\s*(.+)"
artist = ""
```

No code changes needed.
```

- [ ] **Step 2: Commit**

```bash
git add homerip/README.md
git commit -m "Add homerip README"
```

---

## Self-Review Notes

- **Spec coverage:** Cargo scaffold (Task 1), sanitize_title port (Task 2), series.toml config for all 3 series (Task 3), episode matching + canonical naming (Task 4), local dedup check (Task 5), TOC/disc-ID (Task 6), MusicBrainz client with mockable trait (Task 7), drive detection + dependency check (Task 8), rip.sh subprocess with terminal handoff (Task 9), rename+retag (Task 10), upload.sh subprocess (Task 11), upload.sh Sternenfohlen line (Task 12), wizard state machine covering every screen/error path from the spec (Task 13), full integration (Task 14), docs (Task 15). All spec sections are covered.
- **Placeholder scan:** no `TBD`/`TODO` left in final code blocks — every `todo!()` is replaced within the same task before it's committed.
- **Type consistency:** `Series`, `Episode`, `ReleaseInfo`, `WizardState`, `Screen`, `WizardEvent` are each defined once (Tasks 3, 4, 7, 13) and reused with the same names/fields in Task 14 — checked against each task's Interfaces block.
