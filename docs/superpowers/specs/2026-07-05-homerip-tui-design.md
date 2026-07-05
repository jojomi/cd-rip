# homerip — Rust TUI für CD-Ripping

## Zweck

Geführte TUI (`homerip/`), die den Anwender durch das Rippen von Hörspiel-CDs führt und dabei die bestehende Bash/Python-Tooling in diesem Repo (`rip.sh`, `upload.sh`, Tag-Konventionen) im Hintergrund als Subprozesse nutzt. Unterstützt die Serien "Bibi und Tina", "Sternenfohlen" und "Horse Club" inklusive automatischem Rename/Retag auf ein einheitliches Dateischema und Upload nach up.slzm.de. Rippt nur, was im Zielordner noch nicht vorhanden ist.

## Architektur

- Cargo-Binärprojekt in `homerip/`, TUI mit `ratatui` + `crossterm`.
- Die eigentliche Rip-Technik (abcde/cdparanoia/opusenc) bleibt in `rip.sh` — die TUI ruft es als Subprozess auf und übergibt dafür kurz die Terminal-Kontrolle (raw mode aus, inherit stdio), damit abcde/cdparanoia normal in die Konsole schreiben können. Nach Rückkehr des Subprozesses übernimmt die TUI das Terminal wieder (alternate screen erneut aktivieren).
- Upload läuft über das bestehende `upload.sh` (rsync `--ignore-existing`), ebenfalls als Subprozess.
- Einzige in Rust neu implementierte Logik: der schnelle Disc-TOC-Lookup gegen MusicBrainz (Portierung von `get_mb_info()` aus `rip.sh`: `cdparanoia -Q` TOC lesen, MusicBrainz-Disc-ID berechnen, MusicBrainz-API abfragen) sowie `sanitize_title()`. Beides wird gebraucht, um Serie/Folge/Titel *vor* dem eigentlichen Rippen zu kennen — nötig für den Dedup-Check.

## Serien-Konfiguration

`homerip/series.toml`, eine Liste von Serien-Einträgen:

```toml
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

[[series]]
key = "sternenfohlen"
display_name = "Sternenfohlen"
file_prefix = "Sternenfohlen"
title_regex = "Sternenfohlen,?\\s*Folge\\s+(\\d+):?\\s*(.+)"
artist = ""
```

Kanonisches Dateischema pro Serie: `{file_prefix}_Folge_{NNN}_{sanitized_subtitle}.opus`, Tag-Titel `{display_name}, Folge {N}: {subtitle}`. Eine neue Serie hinzuzufügen erfordert nur einen neuen TOML-Block, keine Code-Änderung.

## Wizard-Ablauf

Ein Durchlauf pro eingelegter CD, danach zurück zur Serienwahl (Batch-Session für mehrere CDs hintereinander):

1. **Serie wählen** aus `series.toml`.
2. **CD-Laufwerk & Medium prüfen** (Portierung von `find_drive`/`check_medium` aus `rip.sh`).
3. **TOC-Lookup + MusicBrainz-Query** (Rust) → Titel/Artist-Kandidat.
4. **Serien-Regex** extrahiert Folge-Nummer + Untertitel aus dem MusicBrainz-Titel. Kein MusicBrainz-Treffer oder Regex passt nicht → manuelle Eingabe von Folge-Nummer und Untertitel.
5. **Kanonischen Dateinamen bauen** aus Serie + Folge-Nummer + sanitized Untertitel.
6. **Dedup-Check**: Existiert diese Datei bereits im Zielordner (lokal, `Ripping/`)? Falls ja: Menü **Überspringen** / **Trotzdem rippen** / **Abbrechen**.
7. **Bestätigungsscreen**: Serie, Folge, Titel, geplanter Dateiname — bestätigen oder abbrechen.
8. **Rip starten**: `rip.sh --title "<MusicBrainz-Titel>" --artist "<Artist>" --single --yes <Ripping-Verzeichnis>` als Subprozess (Terminal-Übergabe wie oben beschrieben).
9. **Nach erfolgreichem Rip**: Ausgabedatei von `rip.sh` (Name basiert auf sanitisiertem MusicBrainz-Rohtitel) auf das kanonische Schema umbenennen und den TITLE/ALBUM-Tag auf `{display_name}, Folge {N}: {subtitle}` setzen (kleines Python/Mutagen-Heredoc, analog zu `fix-title.sh`).
10. **Upload-Frage**: Jetzt hochladen? Ja → `./upload.sh` im Ripping-Verzeichnis als Subprozess ausführen, Ausgabe live anzeigen.
11. Zurück zu Schritt 1 (nächste CD) oder Beenden.

Zielverzeichnis für Rips ist standardmäßig das bestehende `Ripping/`-Verzeichnis (konfigurierbar, Default bleibt dieser Pfad).

## Fehlerbehandlung

- Kein Laufwerk / keine Audio-CD erkannt → klare Fehlermeldung mit Ursachen (wie in `rip.sh`), Retry-Option.
- MusicBrainz-Lookup schlägt fehl oder Serien-Regex matcht nicht → Fallback auf manuelle Eingabe, kein Abbruch.
- Dedup-Treffer → explizites Menü, kein stilles Überspringen.
- `rip.sh` beendet mit Fehlercode → Fehler anzeigen, kein automatisches Rename/Upload, zurück ins Serienmenü.
- Start-Dependency-Check (abcde, cdparanoia, cd-discid, python3 + python-mutagen, rsync) beim TUI-Start, bevor der Wizard beginnt — analog zu `check_dependencies()` in `rip.sh`.

## upload.sh Änderung

Ergänzung einer Zeile für Sternenfohlen (Horse-Club-Zeile existiert bereits):

```bash
rsync --ignore-missing-args --ignore-existing --progress Sternenfohlen_*.opus "${REMOTE}/Sternenfohlen/"
```

## Tests

- Unit-Tests (Rust): `sanitize_title`-Portierung, Dateiname-Builder pro Serie, Serien-Regex-Parsing (inkl. Negativfälle), Laden/Validieren von `series.toml`.
- MusicBrainz-API-Aufruf hinter einem Trait/Interface, damit er in Tests mit Fixture-JSON gemockt werden kann (kein echter Netzwerkzugriff in Unit-Tests).
- End-to-End (echter Rip mit CD im Laufwerk) ist hardware-/netzwerkabhängig und nur manuell testbar.
