#!/bin/bash
# rip.sh – CD ripping script for Linux/Manjaro
# Rips an audio CD using abcde and encodes to Opus
# Usage: ./rip.sh [OUTPUT_DIRECTORY]
#   OUTPUT_DIRECTORY: target folder for Opus files (default: current directory)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Helper functions ─────────────────────────────────────────────────────────
error() {
    echo -e "${RED}✗ ERROR:${RESET} $*" >&2
}

warning() {
    echo -e "${YELLOW}⚠ WARNING:${RESET} $*"
}

info() {
    echo -e "${BLUE}→${RESET} $*"
}

success() {
    echo -e "${GREEN}✓${RESET} $*"
}

separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────${RESET}"
}

# Format seconds as "M:SS" or "H:MM:SS"
format_duration() {
    local seconds=$1
    local hours=$(( seconds / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$(( seconds % 60 ))
    if (( hours > 0 )); then
        printf "%d:%02d:%02d" "$hours" "$minutes" "$secs"
    else
        printf "%d:%02d" "$minutes" "$secs"
    fi
}

# Human-readable size of a file or directory
file_size() {
    local path="$1"
    if [[ -f "$path" || -d "$path" ]]; then
        du -sh "$path" 2>/dev/null | cut -f1
    else
        echo "?"
    fi
}

# ─── Cleanup on exit ──────────────────────────────────────────────────────────
ABCDE_CONF_BACKUP=""
ABCDE_CONF_CREATED=false

cleanup() {
    local exit_code=$?
    if [[ -n "$ABCDE_CONF_BACKUP" && -f "$ABCDE_CONF_BACKUP" ]]; then
        mv "$ABCDE_CONF_BACKUP" "$HOME/.abcde.conf"
        info "Original ~/.abcde.conf restored."
    elif [[ "$ABCDE_CONF_CREATED" == true && -f "$HOME/.abcde.conf" ]]; then
        rm -f "$HOME/.abcde.conf"
    fi
    exit $exit_code
}
trap cleanup EXIT

# ─── Dependency check ─────────────────────────────────────────────────────────
check_dependencies() {
    # Tool → package name (pacman, official repos)
    local tools=("abcde" "opusenc" "cdparanoia" "cd-discid" "wget" "eject" "python3")
    local packages=("abcde" "opus-tools" "cdparanoia" "cd-discid" "wget" "eject" "python")

    local errors_found=false
    local missing_tools=()
    local missing_packages=()

    for i in "${!tools[@]}"; do
        if ! command -v "${tools[$i]}" &>/dev/null; then
            missing_tools+=("${tools[$i]}")
            missing_packages+=("${packages[$i]}")
            errors_found=true
        fi
    done

    if [[ "$errors_found" == true ]]; then
        error "The following required programs are not installed:"
        echo ""
        for i in "${!missing_tools[@]}"; do
            echo -e "  ${BOLD}${missing_tools[$i]}${RESET} → ${YELLOW}sudo pacman -S ${missing_packages[$i]}${RESET}"
        done
        echo ""
        info "Install all missing programs at once:"
        local packages_list="${missing_packages[*]}"
        echo -e "  ${YELLOW}sudo pacman -S ${packages_list}${RESET}"
        echo ""
        exit 1
    fi

    # Check Python module mutagen (used for tagging the combined Opus file)
    if ! python3 -c 'import mutagen.oggopus' &>/dev/null; then
        error "Python module ${BOLD}mutagen${RESET}${RED} is missing."
        echo ""
        echo -e "  Install with: ${YELLOW}sudo pacman -S python-mutagen${RESET}"
        echo ""
        exit 1
    fi

    success "All required programs are installed."
}

# ─── Perl module check for multi-track mode ───────────────────────────────────
# In single-file mode abcde-musicbrainz-tool is not called,
# so these modules are not needed there.
check_perl_modules() {
    local perl_modules_missing=false
    if ! perl -e 'use MusicBrainz::DiscID' &>/dev/null; then
        perl_modules_missing=true
    fi
    if ! perl -e 'use WebService::MusicBrainz' &>/dev/null; then
        perl_modules_missing=true
    fi
    if [[ "$perl_modules_missing" == true ]]; then
        error "Missing Perl modules for abcde-musicbrainz-tool."
        echo ""
        echo -e "  ${BOLD}MusicBrainz::DiscID${RESET}  and/or  ${BOLD}WebService::MusicBrainz${RESET}"
        echo -e "  are required by abcde for track metadata in multi-track mode."
        echo ""
        echo -e "  Install via AUR (one of the following):"
        echo -e "    ${YELLOW}pamac install perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo -e "    ${YELLOW}yay -S perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo -e "    ${YELLOW}paru -S perl-musicbrainz-discid perl-webservice-musicbrainz${RESET}"
        echo ""
        exit 1
    fi
}

# ─── Find CD drive ────────────────────────────────────────────────────────────
find_drive() {
    local candidates=("/dev/cdrom" "/dev/sr0" "/dev/sr1" "/dev/sr2")

    for device in "${candidates[@]}"; do
        if [[ -b "$device" ]]; then
            echo "$device"
            return 0
        fi
    done

    error "No CD-ROM drive found."
    echo ""
    info "Checked device files: ${candidates[*]}"
    info "Possible causes:"
    echo "  • No optical drive connected or detected"
    echo "  • Drive has a different device name"
    echo "    Check with: ls /dev/sr* /dev/cdrom 2>/dev/null"
    echo "  • Kernel module not loaded"
    echo "    Check with: lsmod | grep -i cdrom"
    exit 1
}

# ─── Check CD medium ──────────────────────────────────────────────────────────
check_medium() {
    local device="$1"

    info "Checking for audio CD in ${BOLD}${device}${RESET} ..."

    if ! cd-discid "$device" &>/dev/null; then
        error "No audio CD found in ${device}."
        echo ""
        info "Possible causes:"
        echo "  • No disc inserted → insert CD and restart the script"
        echo "  • Disc is not an audio CD (e.g. DVD or data CD)"
        echo "  • Drive not responding → eject and reinsert the CD"
        echo "  • Missing read permission:"
        echo "    Check with: ls -la ${device}"
        echo "    Add user to 'optical' group: sudo usermod -aG optical \$USER"
        echo "    (then log out and back in)"
        exit 1
    fi

    success "Audio CD detected."
}

# ─── MusicBrainz title lookup ─────────────────────────────────────────────────
# Outputs "TITLE\tARTIST" (tab-separated) or nothing on failure.
# Calculates the MusicBrainz disc ID from the cdparanoia TOC (no extra tool needed).
get_mb_info() {
    local device="$1"
    local toc_output

    toc_output=$(cdparanoia -Q -d "$device" 2>&1) || return 1

    # Python (stdlib) calculates MB disc ID and queries the API
    TOC_DATA="$toc_output" python3 << 'PYEOF'
import os, re, hashlib, base64, json, sys
import urllib.request, urllib.error

toc_text = os.environ.get("TOC_DATA", "")

# Parse cdparanoia -Q output
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

# MusicBrainz disc ID: SHA-1 over TOC data, base64-encoded
data = "%02X%02X" % (first_track, last_track)
data += "%08X" % leadout
for i in range(99):
    data += "%08X" % offsets[i] if i < len(offsets) else "00000000"

digest  = hashlib.sha1(data.encode("ascii")).digest()
b64     = base64.b64encode(digest).decode("ascii")
disc_id = b64.replace("+", ".").replace("/", "_").replace("=", "-")

# Query MusicBrainz API
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
    # Assemble artist name
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

# ─── Sanitize title for filesystem ────────────────────────────────────────────
sanitize_title() {
    local title="$1"
    echo "$title" \
        | tr '/' '-' \
        | tr ':' '_' \
        | sed 's/[[:space:]]\+/_/g' \
        | sed 's/[*?"<>|\\,&]//g' \
        | sed 's/^[._-]*//' \
        | sed 's/[._-]*$//' \
        | sed 's/_\+/_/g'
}

# ─── Write abcde configuration ────────────────────────────────────────────────
write_abcde_config() {
    local safe_title="$1"
    local single_file="$2"
    local output_dir="$3"
    local cpu_cores
    cpu_cores=$(nproc)

    # Back up existing configuration
    if [[ -f "$HOME/.abcde.conf" ]]; then
        ABCDE_CONF_BACKUP=$(mktemp "${HOME}/.abcde.conf.bak.XXXXXX")
        cp "$HOME/.abcde.conf" "$ABCDE_CONF_BACKUP"
        info "Existing ~/.abcde.conf backed up as $(basename "$ABCDE_CONF_BACKUP")"
    else
        ABCDE_CONF_CREATED=true
    fi

    # Mode-specific settings
    local format_line cddb_lines actions_line
    if [[ "$single_file" == true ]]; then
        # No MusicBrainz call – metadata is set after ripping via mutagen
        format_line="ONETRACKOUTPUTFORMAT='${safe_title}'"
        cddb_lines="NOCDDBQUERY=y
INTERACTIVE=n"
        actions_line="ACTIONS=read,encode,move,clean"
    else
        format_line="OUTPUTFORMAT='${safe_title}/\${TRACKNUM}.\${TRACKFILE}'"
        cddb_lines="CDDBMETHOD=musicbrainz"
        actions_line="ACTIONS=cddb,read,encode,tag,move,clean"
    fi

    cat > "$HOME/.abcde.conf" << EOF
# Temporary abcde configuration – created by rip.sh
# Will be automatically removed/restored after ripping.

# Metadata source
${cddb_lines}

# Output format
OUTPUTTYPE=opus
OPUSENCODERSYNTAX=default
OPUSENCOPTS="--bitrate 192"

# Output directory and filename format
OUTPUTDIR="${output_dir}"
${format_line}

# Performance: use all ${cpu_cores} CPU cores, parallel read+encode
MAXPROCS=${cpu_cores}
LOWDISK=n
READNICE=0
ENCNICE=0

# Quality and behaviour
PADTRACKS=y
EJECTCD=y
EXTRAVERBOSE=1

# CD reader (cdparanoia with standard error correction)
CDROMREADERSYNTAX=cdparanoia
CDPARANOIAOPTS=""

# Actions
${actions_line}
EOF
}

# ─── Set Opus metadata (single-file mode) ────────────────────────────────────
# Uses python-mutagen: writes Ogg Vorbis Comments directly into the file.
set_opus_metadata() {
    local file="$1"
    local title="$2"
    local artist="$3"

    if [[ ! -f "$file" ]]; then
        warning "Output file not found, could not set metadata: ${file}"
        return
    fi

    info "Setting metadata on ${BOLD}$(basename "$file")${RESET} ..."

    if python3 - "$file" "$title" "$artist" << 'PYEOF'
import sys
from mutagen.oggopus import OggOpus

file, title, artist = sys.argv[1], sys.argv[2], sys.argv[3]

audio = OggOpus(file)
audio["TITLE"]  = [title]
audio["ALBUM"]  = [title]
if artist:
    audio["ARTIST"]      = [artist]
    audio["ALBUMARTIST"] = [artist]
audio.save()
PYEOF
    then
        success "Metadata set: TITLE=${title}${artist:+, ARTIST=${artist}}"
    else
        warning "Failed to set metadata (file will remain untagged)."
    fi
}

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
Usage: rip.sh [OPTIONS] [OUTPUT_DIRECTORY]

Rips an audio CD to Opus files using abcde + cdparanoia.
Album metadata is fetched automatically from MusicBrainz.

OPTIONS
  -h, --help    Show this help and exit

OUTPUT_DIRECTORY
  Directory where the Opus file(s) will be placed.
  Created automatically if it does not exist.
  Defaults to the current directory.

OUTPUT MODES (chosen interactively)
  Single file    All tracks merged into one .opus file — ideal for audiobooks
                 and audio dramas. Metadata is applied via python-mutagen.
  Per track      One .opus file per track inside a named subfolder.
                 Track metadata is fetched from MusicBrainz by abcde.

EXAMPLES
  rip.sh                        Rip to current directory
  rip.sh ~/music                Rip to ~/music
  rip.sh ~/audiobooks           Rip audiobook CD to ~/audiobooks
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    local start_total=$SECONDS

    # Output directory from first argument or current directory
    local output_dir
    if [[ $# -ge 1 ]]; then
        if [[ "$1" == "--help" || "$1" == "-h" ]]; then
            show_help
            exit 0
        fi
        output_dir="$1"
        if [[ ! -d "$output_dir" ]]; then
            mkdir -p "$output_dir" || {
                error "Could not create output directory: ${output_dir}"
                exit 1
            }
        fi
        output_dir="$(realpath "$output_dir")"
    else
        output_dir="$(pwd)"
    fi

    clear
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║       CD Ripper  →  Opus Encoder         ║${RESET}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${RESET}"
    echo ""

    # 1. Check dependencies
    separator
    info "Checking system requirements ..."
    check_dependencies
    echo ""

    # 2. Find CD drive
    local cdrom_device
    cdrom_device=$(find_drive)
    success "CD-ROM drive found: ${BOLD}${cdrom_device}${RESET}"

    # 3. Check medium
    check_medium "$cdrom_device"
    echo ""

    # 4. MusicBrainz lookup (best-effort, silent on failure)
    separator
    echo -e "${BOLD}Settings:${RESET}"
    echo ""

    local cd_title=""
    local mb_artist=""   # may be empty if no MB entry or no artist known
    local mb_info=""

    info "Looking up CD in MusicBrainz database ..."
    mb_info=$(get_mb_info "$cdrom_device" 2>/dev/null) || mb_info=""

    if [[ -n "$mb_info" ]]; then
        local mb_title
        mb_title=$(echo "$mb_info" | cut -f1)
        mb_artist=$(echo "$mb_info" | cut -f2)

        echo ""
        if [[ -n "$mb_artist" ]]; then
            success "MusicBrainz entry found: ${BOLD}${mb_title}${RESET} (${mb_artist})"
        else
            success "MusicBrainz entry found: ${BOLD}${mb_title}${RESET}"
        fi
        echo ""

        local override=""
        read -r -p "$(echo -e "  Enter custom title? (leave empty to keep MusicBrainz title): ")" override

        if [[ -n "$override" ]]; then
            cd_title="$override"
        else
            cd_title="$mb_title"
        fi
    else
        warning "No MusicBrainz entry found (no network, unknown CD, or timeout)."
        echo ""

        while [[ -z "$cd_title" ]]; do
            read -r -p "$(echo -e "  ${BOLD}CD title:${RESET} ")" cd_title
            if [[ -z "$cd_title" ]]; then
                warning "Title must not be empty. Please try again."
            fi
        done
    fi

    local safe_title
    safe_title=$(sanitize_title "$cd_title")

    echo ""
    if [[ "$safe_title" != "$cd_title" ]]; then
        info "Title adjusted for filename: ${BOLD}${safe_title}${RESET}"
    else
        info "Title: ${BOLD}${safe_title}${RESET}"
    fi

    # 5. Single file or individual tracks?
    echo ""
    local single_file=false
    local mode_answer=""
    read -r -p "$(echo -e "  ${BOLD}Combine all tracks into a single Opus file?${RESET} [y/N]: ")" mode_answer

    if [[ "${mode_answer,,}" == "y" || "${mode_answer,,}" == "j" || "${mode_answer,,}" == "yes" || "${mode_answer,,}" == "ja" ]]; then
        single_file=true
        info "Mode: ${BOLD}Single file${RESET} → ${BOLD}${safe_title}.opus${RESET}"
        info "MusicBrainz skipped during ripping; metadata will be set afterward."
    else
        info "Mode: ${BOLD}Individual tracks${RESET} → folder ${BOLD}${safe_title}/${RESET}"
    fi

    info "Output directory: ${BOLD}${output_dir}${RESET}"

    # 6. In multi-track mode, check Perl modules (needed by abcde-musicbrainz-tool)
    if [[ "$single_file" == false ]]; then
        check_perl_modules
    fi

    # 7. Confirm ripping
    echo ""
    local rip_answer=""
    read -r -p "$(echo -e "  ${BOLD}Start ripping now?${RESET} [Y/n]: ")" rip_answer

    if [[ "${rip_answer,,}" == "n" || "${rip_answer,,}" == "no" || "${rip_answer,,}" == "nein" ]]; then
        info "Aborted. No files were created."
        exit 0
    fi

    echo ""

    # 8. Write configuration
    separator
    local cpu_cores
    cpu_cores=$(nproc)
    info "Creating abcde configuration (${cpu_cores} CPU cores, Opus 192 kbps) ..."
    write_abcde_config "$safe_title" "$single_file" "$output_dir"
    success "Configuration ready."
    echo ""

    # 9. Start abcde
    separator
    echo ""
    echo -e "${BOLD}Starting CD ripping process ...${RESET}"
    if [[ "$single_file" == false ]]; then
        echo -e "${YELLOW}Note:${RESET} Confirm track information interactively if prompted."
    fi
    echo ""

    local start_rip=$SECONDS
    if [[ "$single_file" == true ]]; then
        abcde -d "$cdrom_device" -o opus -1
    else
        abcde -d "$cdrom_device" -o opus
    fi
    local duration_rip=$(( SECONDS - start_rip ))

    # 10. Set metadata on combined file (single-file mode only)
    local duration_merge=0
    if [[ "$single_file" == true ]]; then
        echo ""
        separator
        local start_merge=$SECONDS
        set_opus_metadata \
            "${output_dir}/${safe_title}.opus" \
            "$cd_title" \
            "$mb_artist"
        duration_merge=$(( SECONDS - start_merge ))
    fi

    # 11. Summary
    local duration_total=$(( SECONDS - start_total ))
    echo ""
    separator
    success "${BOLD}Ripping complete!${RESET}"
    echo ""

    if [[ "$single_file" == true ]]; then
        local output_file="${output_dir}/${safe_title}.opus"
        if [[ -f "$output_file" ]]; then
            local size
            size=$(file_size "$output_file")
            success "File saved:  ${BOLD}${output_file}${RESET}"
            success "File size:   ${BOLD}${size}${RESET}"
        else
            info "File should be located in: ${BOLD}${output_dir}/${RESET}"
            warning "Filename may differ slightly."
        fi
    else
        local out_folder="${output_dir}/${safe_title}"
        if [[ -d "$out_folder" ]]; then
            local count size
            count=$(find "$out_folder" -name "*.opus" 2>/dev/null | wc -l)
            size=$(file_size "$out_folder")
            success "Files saved to: ${BOLD}${out_folder}/${RESET}"
            success "${count} Opus file(s), total size: ${BOLD}${size}${RESET}"
        else
            info "Files should be located in: ${BOLD}${output_dir}/${RESET}"
            warning "Folder name may differ slightly depending on metadata."
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Elapsed time:${RESET}"
    echo -e "    Ripping/encoding:  $(format_duration "$duration_rip")"
    if [[ "$single_file" == true ]]; then
        echo -e "    Merging/metadata:  $(format_duration "$duration_merge")"
    fi
    echo -e "    Total:             $(format_duration "$duration_total")"
    echo ""
}

main "$@"
