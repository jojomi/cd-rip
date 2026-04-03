#!/bin/bash
# rip.sh – CD-Ripping-Skript für Linux/Manjaro
# Rippt eine Audio-CD mit abcde und encodiert zu Opus
# Verwendung: ./rip.sh [AUSGABEVERZEICHNIS]
#   AUSGABEVERZEICHNIS: Zielordner für Opus-Dateien (Standard: aktuelles Verzeichnis)

set -euo pipefail

# ─── Farben ───────────────────────────────────────────────────────────────────
ROT='\033[0;31m'
GELB='\033[1;33m'
GRUEN='\033[0;32m'
BLAU='\033[0;34m'
FETT='\033[1m'
RESET='\033[0m'

# ─── Hilfsfunktionen ──────────────────────────────────────────────────────────
fehler() {
    echo -e "${ROT}✗ FEHLER:${RESET} $*" >&2
}

warnung() {
    echo -e "${GELB}⚠ WARNUNG:${RESET} $*"
}

info() {
    echo -e "${BLAU}→${RESET} $*"
}

erfolg() {
    echo -e "${GRUEN}✓${RESET} $*"
}

trennlinie() {
    echo -e "${BLAU}────────────────────────────────────────────────────────${RESET}"
}

# Sekunden in "M:SS" bzw. "H:MM:SS" formatieren
formatiere_dauer() {
    local sekunden=$1
    local stunden=$(( sekunden / 3600 ))
    local minuten=$(( (sekunden % 3600) / 60 ))
    local sek=$(( sekunden % 60 ))
    if (( stunden > 0 )); then
        printf "%d:%02d:%02d" "$stunden" "$minuten" "$sek"
    else
        printf "%d:%02d" "$minuten" "$sek"
    fi
}

# Menschenlesbare Dateigröße (Datei oder Verzeichnis)
dateigrösse() {
    local pfad="$1"
    if [[ -f "$pfad" || -d "$pfad" ]]; then
        du -sh "$pfad" 2>/dev/null | cut -f1
    else
        echo "?"
    fi
}

# ─── Cleanup beim Beenden ─────────────────────────────────────────────────────
ABCDE_CONF_BACKUP=""
ABCDE_CONF_NEU_ERSTELLT=false

cleanup() {
    local exit_code=$?
    if [[ -n "$ABCDE_CONF_BACKUP" && -f "$ABCDE_CONF_BACKUP" ]]; then
        mv "$ABCDE_CONF_BACKUP" "$HOME/.abcde.conf"
        info "Originale ~/.abcde.conf wiederhergestellt."
    elif [[ "$ABCDE_CONF_NEU_ERSTELLT" == true && -f "$HOME/.abcde.conf" ]]; then
        rm -f "$HOME/.abcde.conf"
    fi
    exit $exit_code
}
trap cleanup EXIT

# ─── Abhängigkeitsprüfung ─────────────────────────────────────────────────────
pruefe_abhaengigkeiten() {
    # Tool → Paketname (pacman, offizielle Repos)
    local tools=("abcde" "opusenc" "cdparanoia" "cd-discid" "wget" "eject" "python3")
    local pakete=("abcde" "opus-tools" "cdparanoia" "cd-discid" "wget" "eject" "python")

    local fehler_gefunden=false
    local fehlende_tools=()
    local fehlende_pakete=()

    for i in "${!tools[@]}"; do
        if ! command -v "${tools[$i]}" &>/dev/null; then
            fehlende_tools+=("${tools[$i]}")
            fehlende_pakete+=("${pakete[$i]}")
            fehler_gefunden=true
        fi
    done

    if [[ "$fehler_gefunden" == true ]]; then
        fehler "Folgende benötigte Programme sind nicht installiert:"
        echo ""
        for i in "${!fehlende_tools[@]}"; do
            echo -e "  ${FETT}${fehlende_tools[$i]}${RESET} → ${GELB}sudo pacman -S ${fehlende_pakete[$i]}${RESET}"
        done
        echo ""
        info "Alle fehlenden Programme auf einmal installieren:"
        local pakete_liste="${fehlende_pakete[*]}"
        echo -e "  ${GELB}sudo pacman -S ${pakete_liste}${RESET}"
        echo ""
        exit 1
    fi

    # Python-Modul mutagen prüfen (zum Tagging der kombinierten Opus-Datei)
    if ! python3 -c 'import mutagen.oggopus' &>/dev/null; then
        fehler "Python-Modul ${FETT}mutagen${RESET}${ROT} fehlt."
        echo ""
        echo -e "  Installation: ${GELB}sudo pacman -S python-mutagen${RESET}"
        echo ""
        exit 1
    fi

    erfolg "Alle benötigten Programme sind installiert."
}

# ─── Perl-Module für Multi-Track-Modus prüfen ────────────────────────────────
# Im Einzeldatei-Modus wird abcde-musicbrainz-tool nicht aufgerufen,
# daher sind diese Module dort nicht nötig.
pruefe_perl_module() {
    local perl_module_fehlen=false
    if ! perl -e 'use MusicBrainz::DiscID' &>/dev/null; then
        perl_module_fehlen=true
    fi
    if ! perl -e 'use WebService::MusicBrainz' &>/dev/null; then
        perl_module_fehlen=true
    fi
    if [[ "$perl_module_fehlen" == true ]]; then
        fehler "Fehlende Perl-Module für abcde-musicbrainz-tool."
        echo ""
        echo -e "  ${FETT}MusicBrainz::DiscID${RESET}  und/oder  ${FETT}WebService::MusicBrainz${RESET}"
        echo -e "  werden von abcde für Track-Metadaten im Mehrspurdatei-Modus benötigt."
        echo ""
        echo -e "  Installation über AUR (eines der folgenden):"
        echo -e "    ${GELB}pamac install perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo -e "    ${GELB}yay -S perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo -e "    ${GELB}paru -S perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo ""
        exit 1
    fi
}

# ─── CD-Laufwerk finden ───────────────────────────────────────────────────────
finde_laufwerk() {
    local kandidaten=("/dev/cdrom" "/dev/sr0" "/dev/sr1" "/dev/sr2")

    for geraet in "${kandidaten[@]}"; do
        if [[ -b "$geraet" ]]; then
            echo "$geraet"
            return 0
        fi
    done

    fehler "Kein CD-ROM-Laufwerk gefunden."
    echo ""
    info "Geprüfte Gerätedateien: ${kandidaten[*]}"
    info "Mögliche Ursachen:"
    echo "  • Kein optisches Laufwerk angeschlossen oder erkannt"
    echo "  • Laufwerk hat einen anderen Gerätenamen"
    echo "    Prüfen mit: ls /dev/sr* /dev/cdrom 2>/dev/null"
    echo "  • Kernel-Modul nicht geladen"
    echo "    Prüfen mit: lsmod | grep -i cdrom"
    exit 1
}

# ─── CD-Medium prüfen ─────────────────────────────────────────────────────────
pruefe_medium() {
    local geraet="$1"

    info "Prüfe ob eine CD eingelegt ist in ${FETT}${geraet}${RESET} ..."

    if ! cd-discid "$geraet" &>/dev/null; then
        fehler "Keine Audio-CD in ${geraet} gefunden."
        echo ""
        info "Mögliche Ursachen:"
        echo "  • Kein Datenträger eingelegt → CD einlegen und Skript erneut starten"
        echo "  • Datenträger ist keine Audio-CD (z.B. DVD oder Daten-CD)"
        echo "  • Laufwerk reagiert nicht → Laufwerk auswerfen und CD neu einlegen"
        echo "  • Fehlende Leseberechtigung:"
        echo "    Prüfen mit: ls -la ${geraet}"
        echo "    Benutzer zur Gruppe 'optical' hinzufügen: sudo usermod -aG optical \$USER"
        echo "    (danach neu anmelden)"
        exit 1
    fi

    erfolg "Audio-CD erkannt."
}

# ─── MusicBrainz-Titelsuche ───────────────────────────────────────────────────
# Gibt "TITEL\tKÜNSTLER" aus (tab-getrennt) oder nichts bei Fehler.
# Berechnet die MusicBrainz-Disc-ID aus der cdparanoia-TOC (kein extra Tool nötig).
ermittle_mb_info() {
    local geraet="$1"
    local toc_output

    toc_output=$(cdparanoia -Q -d "$geraet" 2>&1) || return 1

    # Python (stdlib) berechnet MB-Disc-ID und fragt die API ab
    TOC_DATA="$toc_output" python3 << 'PYEOF'
import os, re, hashlib, base64, json, sys
import urllib.request, urllib.error

toc_text = os.environ.get("TOC_DATA", "")

# cdparanoia -Q Ausgabe parsen
# Format: "  1.    17640 [03:55.15]        0 [00:00.00]    no   no  2"
track_re = re.compile(
    r"^\s+(\d+)\.\s+(\d+)\s+\[[\d:\.]+\]\s+(\d+)\s+",
    re.MULTILINE
)
tracks = track_re.findall(toc_text)  # [(num, length, begin), ...]

if not tracks:
    sys.exit(1)

track_data = [(int(n), int(length), int(begin)) for n, length, begin in tracks]
first_track = track_data[0][0]
last_track  = track_data[-1][0]
leadout     = track_data[-1][2] + track_data[-1][1] + 150
offsets     = [begin + 150 for _, _, begin in track_data]

# MusicBrainz-Disc-ID: SHA-1 über TOC-Daten, base64-kodiert
data = "%02X%02X" % (first_track, last_track)
data += "%08X" % leadout
for i in range(99):
    data += "%08X" % offsets[i] if i < len(offsets) else "00000000"

digest  = hashlib.sha1(data.encode("ascii")).digest()
b64     = base64.b64encode(digest).decode("ascii")
disc_id = b64.replace("+", ".").replace("/", "_").replace("=", "-")

# MusicBrainz-API abfragen
url = "https://musicbrainz.org/ws/2/discid/" + disc_id + "?fmt=json&inc=artist-credits"
req = urllib.request.Request(
    url,
    headers={"User-Agent": "rip.sh/1.0 (linux cd ripper)"}
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        mb = json.load(resp)
    releases = mb.get("releases", [])
    if not releases:
        sys.exit(1)
    release = releases[0]
    title   = release.get("title", "")
    # Interpreten-Namen zusammensetzen
    artists = release.get("artist-credit", [])
    artist_parts = []
    for a in artists:
        if isinstance(a, dict):
            name = a.get("name") or a.get("artist", {}).get("name", "")
            if name:
                artist_parts.append(name)
            joinphrase = a.get("joinphrase", "")
            if joinphrase:
                artist_parts.append(joinphrase)
    artist = "".join(artist_parts).strip()
    print(f"{title}\t{artist}")
except Exception:
    sys.exit(1)
PYEOF
}

# ─── Titel für Dateisystem bereinigen ────────────────────────────────────────
bereinige_titel() {
    local titel="$1"
    echo "$titel" \
        | tr '/' '-' \
        | tr ':' '_' \
        | sed 's/[[:space:]]\+/_/g' \
        | sed 's/[*?"<>|\\,&]//g' \
        | sed 's/^[._-]*//' \
        | sed 's/[._-]*$//' \
        | sed 's/_\+/_/g'
}

# ─── abcde-Konfiguration schreiben ────────────────────────────────────────────
schreibe_abcde_config() {
    local safe_title="$1"
    local einzeldatei="$2"
    local ausgabeverzeichnis="$3"
    local cpu_kerne
    cpu_kerne=$(nproc)

    # Bestehende Konfiguration sichern
    if [[ -f "$HOME/.abcde.conf" ]]; then
        ABCDE_CONF_BACKUP=$(mktemp "${HOME}/.abcde.conf.bak.XXXXXX")
        cp "$HOME/.abcde.conf" "$ABCDE_CONF_BACKUP"
        info "Bestehende ~/.abcde.conf gesichert als $(basename "$ABCDE_CONF_BACKUP")"
    else
        ABCDE_CONF_NEU_ERSTELLT=true
    fi

    # Modus-abhängige Einstellungen
    local format_zeile cddb_zeilen actions_zeile
    if [[ "$einzeldatei" == true ]]; then
        # Kein MusicBrainz-Aufruf – Metadaten werden nach dem Rippen per opustags gesetzt
        format_zeile="ONETRACKOUTPUTFORMAT='${safe_title}'"
        cddb_zeilen="NOCDDBQUERY=y
INTERACTIVE=n"
        actions_zeile="ACTIONS=read,encode,move,clean"
    else
        format_zeile="OUTPUTFORMAT='${safe_title}/\${TRACKNUM}.\${TRACKFILE}'"
        cddb_zeilen="CDDBMETHOD=musicbrainz"
        actions_zeile="ACTIONS=cddb,read,encode,tag,move,clean"
    fi

    cat > "$HOME/.abcde.conf" << EOF
# Temporäre abcde-Konfiguration – erstellt von rip.sh
# Wird nach dem Rippen automatisch entfernt/wiederhergestellt.

# Metadaten-Quelle
${cddb_zeilen}

# Ausgabeformat
OUTPUTTYPE=opus
OPUSENCODERSYNTAX=default
OPUSENCOPTS="--bitrate 192"

# Ausgabeverzeichnis und Dateinamensformat
OUTPUTDIR="${ausgabeverzeichnis}"
${format_zeile}

# Performance: alle ${cpu_kerne} CPU-Kerne nutzen, parallel lesen+kodieren
MAXPROCS=${cpu_kerne}
LOWDISK=n
READNICE=0
ENCNICE=0

# Qualität und Verhalten
PADTRACKS=y
EJECTCD=y
EXTRAVERBOSE=1

# CD-Leser (cdparanoia mit Standard-Fehlerkorrektur)
CDROMREADERSYNTAX=cdparanoia
CDPARANOIAOPTS=""

# Aktionen
${actions_zeile}
EOF
}

# ─── Opus-Metadaten setzen (Einzeldatei-Modus) ───────────────────────────────
# Verwendet python-mutagen: schreibt Ogg Vorbis Comments direkt in die Datei.
setze_opus_metadaten() {
    local datei="$1"
    local titel="$2"
    local kuenstler="$3"

    if [[ ! -f "$datei" ]]; then
        warnung "Ausgabedatei nicht gefunden, Metadaten konnten nicht gesetzt werden: ${datei}"
        return
    fi

    info "Setze Metadaten auf ${FETT}$(basename "$datei")${RESET} ..."

    if python3 - "$datei" "$titel" "$kuenstler" << 'PYEOF'
import sys
from mutagen.oggopus import OggOpus

datei, titel, kuenstler = sys.argv[1], sys.argv[2], sys.argv[3]

audio = OggOpus(datei)
audio["TITLE"]  = [titel]
audio["ALBUM"]  = [titel]
if kuenstler:
    audio["ARTIST"]      = [kuenstler]
    audio["ALBUMARTIST"] = [kuenstler]
audio.save()
PYEOF
    then
        erfolg "Metadaten gesetzt: TITLE=${titel}${kuenstler:+, ARTIST=${kuenstler}}"
    else
        warnung "Metadaten konnten nicht gesetzt werden (Datei bleibt ungetaggt)."
    fi
}

# ─── Hauptprogramm ────────────────────────────────────────────────────────────
main() {
    local start_gesamt=$SECONDS

    # Ausgabeverzeichnis aus erstem Parameter oder aktuelles Verzeichnis
    local ausgabeverzeichnis
    if [[ $# -ge 1 ]]; then
        ausgabeverzeichnis="$1"
        if [[ ! -d "$ausgabeverzeichnis" ]]; then
            mkdir -p "$ausgabeverzeichnis" || {
                fehler "Ausgabeverzeichnis konnte nicht erstellt werden: ${ausgabeverzeichnis}"
                exit 1
            }
        fi
        ausgabeverzeichnis="$(realpath "$ausgabeverzeichnis")"
    else
        ausgabeverzeichnis="$(pwd)"
    fi

    clear
    echo ""
    echo -e "${FETT}${BLAU}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${FETT}${BLAU}║       CD-Ripper  →  Opus-Encoder         ║${RESET}"
    echo -e "${FETT}${BLAU}╚══════════════════════════════════════════╝${RESET}"
    echo ""

    # 1. Abhängigkeiten prüfen
    trennlinie
    info "Prüfe Systemvoraussetzungen ..."
    pruefe_abhaengigkeiten
    echo ""

    # 2. CD-Laufwerk finden
    local cdrom_device
    cdrom_device=$(finde_laufwerk)
    erfolg "CD-ROM-Laufwerk gefunden: ${FETT}${cdrom_device}${RESET}"

    # 3. Medium prüfen
    pruefe_medium "$cdrom_device"
    echo ""

    # 4. MusicBrainz-Abfrage (best-effort, still bei Fehler)
    trennlinie
    echo -e "${FETT}Einstellungen:${RESET}"
    echo ""

    local cd_titel=""
    local mb_artist=""   # ggf. leer, wenn kein MB-Eintrag oder kein Künstler bekannt
    local mb_info=""

    info "Suche CD in MusicBrainz-Datenbank ..."
    mb_info=$(ermittle_mb_info "$cdrom_device" 2>/dev/null) || mb_info=""

    if [[ -n "$mb_info" ]]; then
        local mb_titel
        mb_titel=$(echo "$mb_info" | cut -f1)
        mb_artist=$(echo "$mb_info" | cut -f2)

        echo ""
        if [[ -n "$mb_artist" ]]; then
            erfolg "MusicBrainz-Eintrag gefunden: ${FETT}${mb_titel}${RESET} (${mb_artist})"
        else
            erfolg "MusicBrainz-Eintrag gefunden: ${FETT}${mb_titel}${RESET}"
        fi
        echo ""

        local override=""
        read -r -p "$(echo -e "  Eigenen Titel eingeben? (leer lassen = MusicBrainz-Titel übernehmen): ")" override

        if [[ -n "$override" ]]; then
            cd_titel="$override"
        else
            cd_titel="$mb_titel"
        fi
    else
        warnung "Kein MusicBrainz-Eintrag gefunden (kein Netz, unbekannte CD, oder Timeout)."
        echo ""

        while [[ -z "$cd_titel" ]]; do
            read -r -p "$(echo -e "  ${FETT}CD-Titel:${RESET} ")" cd_titel
            if [[ -z "$cd_titel" ]]; then
                warnung "Der Titel darf nicht leer sein. Bitte erneut eingeben."
            fi
        done
    fi

    local safe_title
    safe_title=$(bereinige_titel "$cd_titel")

    echo ""
    if [[ "$safe_title" != "$cd_titel" ]]; then
        info "Titel für Dateinamen angepasst: ${FETT}${safe_title}${RESET}"
    else
        info "Titel: ${FETT}${safe_title}${RESET}"
    fi

    # 5. Einzeldatei oder Einzeltracks?
    echo ""
    local einzeldatei=false
    local modus_antwort=""
    read -r -p "$(echo -e "  ${FETT}Alle Tracks zu einer einzigen Opus-Datei zusammenfassen?${RESET} [j/N]: ")" modus_antwort

    if [[ "${modus_antwort,,}" == "y" || "${modus_antwort,,}" == "j" || "${modus_antwort,,}" == "Y" || "${modus_antwort,,}" == "J" || "${modus_antwort,,}" == "ja" ]]; then
        einzeldatei=true
        info "Modus: ${FETT}Einzeldatei${RESET} → ${FETT}${safe_title}.opus${RESET}"
        info "MusicBrainz wird beim Rippen übersprungen; Metadaten werden danach gesetzt."
    else
        info "Modus: ${FETT}Einzelne Tracks${RESET} → Ordner ${FETT}${safe_title}/${RESET}"
    fi

    info "Ausgabeverzeichnis: ${FETT}${ausgabeverzeichnis}${RESET}"

    # 6. Im Mehrspurdatei-Modus Perl-Module prüfen (werden von abcde-musicbrainz-tool benötigt)
    if [[ "$einzeldatei" == false ]]; then
        pruefe_perl_module
    fi

    # 7. Ripping bestätigen
    echo ""
    local rippen_antwort=""
    read -r -p "$(echo -e "  ${FETT}Jetzt rippen?${RESET} [J/n]: ")" rippen_antwort

    if [[ "${rippen_antwort,,}" == "n" ||  "${rippen_antwort,,}" == "N" || "${rippen_antwort,,}" == "nein" ]]; then
        info "Abgebrochen. Keine Dateien wurden erstellt."
        exit 0
    fi

    echo ""

    # 8. Konfiguration schreiben
    trennlinie
    local cpu_kerne
    cpu_kerne=$(nproc)
    info "Erstelle abcde-Konfiguration (${cpu_kerne} CPU-Kerne, Opus 192 kbps) ..."
    schreibe_abcde_config "$safe_title" "$einzeldatei" "$ausgabeverzeichnis"
    erfolg "Konfiguration bereit."
    echo ""

    # 9. abcde starten
    trennlinie
    echo ""
    echo -e "${FETT}Starte CD-Ripping-Prozess ...${RESET}"
    if [[ "$einzeldatei" == false ]]; then
        echo -e "${GELB}Hinweis:${RESET} Trackinformationen bei Bedarf interaktiv bestätigen."
    fi
    echo ""

    local start_rip=$SECONDS
    if [[ "$einzeldatei" == true ]]; then
        abcde -d "$cdrom_device" -o opus -1
    else
        abcde -d "$cdrom_device" -o opus
    fi
    local dauer_rip=$(( SECONDS - start_rip ))

    # 10. Metadaten auf kombinierte Datei setzen (nur Einzeldatei-Modus)
    local dauer_merge=0
    if [[ "$einzeldatei" == true ]]; then
        echo ""
        trennlinie
        local start_merge=$SECONDS
        setze_opus_metadaten \
            "${ausgabeverzeichnis}/${safe_title}.opus" \
            "$cd_titel" \
            "$mb_artist"
        dauer_merge=$(( SECONDS - start_merge ))
    fi

    # 11. Erfolgsmeldung
    local dauer_gesamt=$(( SECONDS - start_gesamt ))
    echo ""
    trennlinie
    erfolg "${FETT}Ripping abgeschlossen!${RESET}"
    echo ""

    if [[ "$einzeldatei" == true ]]; then
        local ausgabedatei="${ausgabeverzeichnis}/${safe_title}.opus"
        if [[ -f "$ausgabedatei" ]]; then
            local groesse
            groesse=$(dateigrösse "$ausgabedatei")
            erfolg "Datei gespeichert: ${FETT}${ausgabedatei}${RESET}"
            erfolg "Dateigröße:        ${FETT}${groesse}${RESET}"
        else
            info "Datei sollte sich befinden in: ${FETT}${ausgabeverzeichnis}/${RESET}"
            warnung "Dateiname kann leicht abweichen."
        fi
    else
        local ausgabeordner="${ausgabeverzeichnis}/${safe_title}"
        if [[ -d "$ausgabeordner" ]]; then
            local anzahl groesse
            anzahl=$(find "$ausgabeordner" -name "*.opus" 2>/dev/null | wc -l)
            groesse=$(dateigrösse "$ausgabeordner")
            erfolg "Dateien gespeichert in: ${FETT}${ausgabeordner}/${RESET}"
            erfolg "${anzahl} Opus-Datei(en), Gesamtgröße: ${FETT}${groesse}${RESET}"
        else
            info "Dateien sollten sich befinden in: ${FETT}${ausgabeverzeichnis}/${RESET}"
            warnung "Ordnername kann je nach Metadaten leicht abweichen."
        fi
    fi

    echo ""
    echo -e "  ${FETT}Laufzeiten:${RESET}"
    echo -e "    Rippen/Kodieren:  $(formatiere_dauer "$dauer_rip")"
    if [[ "$einzeldatei" == true ]]; then
        echo -e "    Mergen/Metadaten: $(formatiere_dauer "$dauer_merge")"
    fi
    echo -e "    Gesamt:           $(formatiere_dauer "$dauer_gesamt")"
    echo ""
}

main "$@"
