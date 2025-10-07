#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

EXIT_SUCCESS=0
EXIT_INVALID_ARGS=1
EXIT_FILE_NOT_FOUND=2
EXIT_INVALID_PDF=3
EXIT_DEPENDENCY_MISSING=4

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] A.pdf B.pdf

Compare two PDF files and generate a visual diff overlay showing additions (red)
and deletions (blue).

Arguments:
  A.pdf                 Original PDF file
  B.pdf                 Modified PDF file

Options:
  -h, --help           Show this help message and exit
  -v, --version        Show version information and exit
  -c, --clean          Remove intermediate files, keep only final PDFs

Environment Variables:
  DPI                  Rasterization DPI (default: 300)
  THRESH               Ink detection threshold, 60-90 typical (default: 80)
  BLUR                 Blur to reduce AA noise (default: 0x1)
  OUT                  Output directory (default: diff_out)
  SXS                  Generate side-by-side PDF: 1=yes, 0=no (default: 1)
  SHOW_LEGEND          Show color legend on overlay: 1=yes, 0=no (default: 1)
  LEGEND_POSITION      Legend position: top-left, top-right, bottom-left, bottom-right (default: bottom-right)
  OVERLAY_OPACITY      Overlay opacity percentage, 0-100 (default: 100)
  PAGES                Page range to process, e.g., "1-5,10,15-20" (default: all)
  PARALLEL_JOBS        Number of parallel jobs for GNU parallel (default: auto)

Examples:
  $0 old.pdf new.pdf
  DPI=150 THRESH=70 $0 old.pdf new.pdf
  OUT=my_diff SXS=0 $0 old.pdf new.pdf
  $0 --clean old.pdf new.pdf

Output:
  overlay.diff.pdf      Modified PDF with red (additions) and blue (deletions)
  side-by-side.pdf      Three-column view: original | modified | overlay

Exit Codes:
  0    Success
  1    Invalid arguments
  2    File not found
  3    Invalid PDF file
  4    Missing dependency (ImageMagick)
EOF
}

show_version() {
    echo "auto-redline version $VERSION"
}

log_info() {
    echo "$@"
}

log_error() {
    echo "Error: $@" >&2
}

check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command '$1' not found. Please install ImageMagick."
        exit $EXIT_DEPENDENCY_MISSING
    fi
}

detect_imagemagick_version() {
    if command -v magick &>/dev/null; then
        echo "magick"
    elif command -v convert &>/dev/null; then
        echo "convert"
    else
        log_error "Neither 'magick' (IM7) nor 'convert' (IM6) found. Please install ImageMagick."
        exit $EXIT_DEPENDENCY_MISSING
    fi
}

parse_page_ranges() {
    local ranges="$1"
    local -a page_nums=()
    
    IFS=',' read -ra range_parts <<< "$ranges"
    for part in "${range_parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for ((i=start; i<=end; i++)); do
                page_nums+=("$i")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            page_nums+=("$part")
        fi
    done
    
    printf '%s\n' "${page_nums[@]}" | sort -nu
}

should_process_page() {
    local page_num="$1"
    local page_ranges="$2"
    
    if [[ -z "$page_ranges" ]]; then
        return 0
    fi
    
    while IFS= read -r allowed_page; do
        if [[ "$page_num" == "$allowed_page" ]]; then
            return 0
        fi
    done < <(parse_page_ranges "$page_ranges")
    
    return 1
}

add_legend() {
    local img="$1"
    local legend_bg="${LEGEND_BG:-white}"
    local legend_border="${LEGEND_BORDER:-black}"
    local legend_text="${LEGEND_TEXT:-black}"
    local legend_pos="${LEGEND_POSITION:-bottom-right}"

    read img_w img_h <<< "$(identify -format "%w %h" "$img")"

    local margin=20
    local legend_w=200
    local legend_h=100
    
    local x1 y1 x2 y2
    case "$legend_pos" in
        top-left)
            x1=$margin
            y1=$margin
            x2=$((margin + legend_w))
            y2=$((margin + legend_h))
            ;;
        top-right)
            x1=$((img_w - legend_w - margin))
            y1=$margin
            x2=$((img_w - margin))
            y2=$((margin + legend_h))
            ;;
        bottom-left)
            x1=$margin
            y1=$((img_h - legend_h - margin))
            x2=$((margin + legend_w))
            y2=$((img_h - margin))
            ;;
        bottom-right|*)
            x1=$((img_w - legend_w - margin))
            y1=$((img_h - legend_h - margin))
            x2=$((img_w - margin))
            y2=$((img_h - margin))
            ;;
    esac

    "$CONVERT_CMD" "$img" \
        -pointsize 18 -font Helvetica \
        -fill "$legend_bg" -stroke "$legend_border" -strokewidth 2 \
        -draw "rectangle $x1,$y1 $x2,$y2" \
        -fill "$legend_text" -stroke none \
        -draw "text $((x1 + 10)),$((y1 + 22)) 'Legend:'" \
        -fill "$COLOR_ADD" \
        -draw "rectangle $((x1 + 10)),$((y1 + 30)) $((x1 + 35)),$((y1 + 50))" \
        -fill "$legend_text" \
        -draw "text $((x1 + 45)),$((y1 + 47)) 'Additions'" \
        -fill "$COLOR_DELETE" \
        -draw "rectangle $((x1 + 10)),$((y1 + 55)) $((x1 + 35)),$((y1 + 75))" \
        -fill "$legend_text" \
        -draw "text $((x1 + 45)),$((y1 + 72)) 'Deletions'" \
        "${img}.tmp"
    
    mv "${img}.tmp" "$img"
    return 0
}

process_pair() {
    local p="$1"
    local q="$2"
    local base="$3"

    # If one side missing, synthesize a white canvas of the other's size
    if [[ ! -f "$p" && -f "$q" ]]; then
        read w h <<< "$(identify -format "%w %h" "$q")"
        "$CONVERT_CMD" -size "${w}x${h}" xc:white "$p"
    elif [[ -f "$p" && ! -f "$q" ]]; then
        read w h <<< "$(identify -format "%w %h" "$p")"
        "$CONVERT_CMD" -size "${w}x${h}" xc:white "$q"
    elif [[ ! -f "$p" && ! -f "$q" ]]; then
        return 0
    fi

    # Binary "ink" masks (white where ink is)
    "$CONVERT_CMD" "$p" -colorspace gray -white-threshold "$WHITE_THRESHOLD" -blur "$BLUR" -threshold "${THRESH}%" -negate -type bilevel "$OUT/$base.Amask.png"
    "$CONVERT_CMD" "$q" -colorspace gray -white-threshold "$WHITE_THRESHOLD" -blur "$BLUR" -threshold "${THRESH}%" -negate -type bilevel "$OUT/$base.Bmask.png"

    # additions = B∖A = B & !A  (boolean via Multiply; no alpha tricks)
    "$CONVERT_CMD" "$OUT/$base.Amask.png" -negate "$OUT/$base.Anot.png"
    "$CONVERT_CMD" "$OUT/$base.Bmask.png" "$OUT/$base.Anot.png" -compose Multiply -composite "$OUT/$base.add.mask.png"

    # deletions = A∖B = A & !B
    "$CONVERT_CMD" "$OUT/$base.Bmask.png" -negate "$OUT/$base.Bnot.png"
    "$CONVERT_CMD" "$OUT/$base.Amask.png" "$OUT/$base.Bnot.png" -compose Multiply -composite "$OUT/$base.del.mask.png"

    # Count changed pixels for statistics
    local add_pixels del_pixels
    add_pixels=$(convert "$OUT/$base.add.mask.png" -format "%[fx:mean*w*h]" info:)
    del_pixels=$(convert "$OUT/$base.del.mask.png" -format "%[fx:mean*w*h]" info:)
    echo "$add_pixels $del_pixels" > "$OUT/$base.stats.txt"

    # Clean & colorize (re-binarize helps; small fuzz aids transparency)
    local opacity="${OVERLAY_OPACITY:-100}"
    "$CONVERT_CMD" "$OUT/$base.add.mask.png" -morphology open "$MORPHOLOGY_RADIUS" -morphology close "$MORPHOLOGY_RADIUS" -threshold "$BINARIZE_THRESHOLD" \
        -fuzz "$TRANSPARENCY_FUZZ" -fill "$COLOR_ADD" -opaque white -transparent black \
        -channel A -evaluate multiply "$((opacity))/100" +channel "$OUT/$base.add.overlay.png"
    "$CONVERT_CMD" "$OUT/$base.del.mask.png" -morphology open "$MORPHOLOGY_RADIUS" -morphology close "$MORPHOLOGY_RADIUS" -threshold "$BINARIZE_THRESHOLD" \
        -fuzz "$TRANSPARENCY_FUZZ" -fill "$COLOR_DELETE" -opaque white -transparent black \
        -channel A -evaluate multiply "$((opacity))/100" +channel "$OUT/$base.del.overlay.png"

    # Compose overlays on NEW page (B): blue first, red on top (so red wins at overlaps)
    composite "$OUT/$base.del.overlay.png" "$q" "$OUT/$base.tmp.png"
    composite "$OUT/$base.add.overlay.png" "$OUT/$base.tmp.png" "$OUT/$base.overlay.png"
    rm -f "$OUT/$base.tmp.png"

    if [[ "${SHOW_LEGEND:-1}" == "1" ]]; then
        add_legend "$OUT/$base.overlay.png"
    fi

    # Optional side-by-side strip
    if [[ "$GENERATE_SIDE_BY_SIDE" == "1" ]]; then
        montage "$p" "$q" "$OUT/$base.overlay.png" -tile 3x1 -geometry "$MONTAGE_GEOMETRY" "$OUT/$base.sxs.png"
    fi
}

# Usage: ./auto-redline.sh A.pdf B.pdf
# Env knobs:
#   DPI=300 THRESH=80 BLUR=0x1 OUT=diff_out SXS=1 ./auto-redline.sh A.pdf B.pdf

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit $EXIT_SUCCESS
fi

if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
    show_version
    exit $EXIT_SUCCESS
fi

CLEAN_MODE=0
if [[ "${1:-}" == "-c" || "${1:-}" == "--clean" ]]; then
    CLEAN_MODE=1
    shift
fi

A="${1:?usage: $0 A.pdf B.pdf}"
B="${2:?usage: $0 A.pdf B.pdf}"

if [[ ! -f "$A" ]]; then
    log_error "File '$A' not found"
    exit $EXIT_FILE_NOT_FOUND
fi

if [[ ! -f "$B" ]]; then
    log_error "File '$B' not found"
    exit $EXIT_FILE_NOT_FOUND
fi

if ! file "$A" | grep -q "PDF"; then
    log_error "'$A' is not a PDF file"
    exit $EXIT_INVALID_PDF
fi

if ! file "$B" | grep -q "PDF"; then
    log_error "'$B' is not a PDF file"
    exit $EXIT_INVALID_PDF
fi

DPI="${DPI:-300}"                 # rasterization DPI
THRESH="${THRESH:-80}"            # 60–90 typical; higher = stricter "ink"
BLUR="${BLUR:-0x1}"               # 0x0–0x1 to reduce AA noise
OUT="${OUT:-diff_out}"            # output dir
GENERATE_SIDE_BY_SIDE="${SXS:-1}" # 1 = also make side-by-side PDF

WHITE_THRESHOLD="95%"
BINARIZE_THRESHOLD="50%"
MORPHOLOGY_RADIUS="disk:1"
TRANSPARENCY_FUZZ="1%"
COLOR_ADD="red"
COLOR_DELETE="blue"
MONTAGE_GEOMETRY="+12+12"

CONVERT_CMD=$(detect_imagemagick_version)

check_dependency "$CONVERT_CMD"
check_dependency composite
check_dependency montage
check_dependency mogrify
check_dependency identify

RASTER_DIR_A=$(mktemp -d -t pdf-diff-a.XXXXXX)
RASTER_DIR_B=$(mktemp -d -t pdf-diff-b.XXXXXX)
mkdir -p "$OUT"

cleanup() {
    log_info "Cleaning up temporary directories..."
    rm -rf "$RASTER_DIR_A" "$RASTER_DIR_B"
}

trap cleanup EXIT INT TERM

log_info "[1/5] Rasterizing PDFs at ${DPI} DPI…"
"$CONVERT_CMD" -density "$DPI" -units PixelsPerInch -background white -alpha remove -alpha off -colorspace sRGB "$A" "$RASTER_DIR_A/page-%05d.png"
"$CONVERT_CMD" -density "$DPI" -units PixelsPerInch -background white -alpha remove -alpha off -colorspace sRGB "$B" "$RASTER_DIR_B/page-%05d.png"

log_info "[2/5] Normalizing canvas sizes page-by-page…"
page_count=$(find "$RASTER_DIR_A" -name "*.png" | wc -l)
current=0

for p in "$RASTER_DIR_A"/*.png; do
    base=$(basename "$p")
    q="$RASTER_DIR_B/$base"
    if [[ -f "$q" ]]; then
        read w h <<< "$(identify -format "%w %h" "$p")"
        read w2 h2 <<< "$(identify -format "%w %h" "$q")"
        W=$((w > w2 ? w : w2))
        H=$((h > h2 ? h : h2))
        mogrify -background white -gravity northwest -extent "${W}x${H}" "$p"
        mogrify -background white -gravity northwest -extent "${W}x${H}" "$q"
    fi
    current=$((current + 1))
    printf "\r  Progress: %d/%d pages normalized" "$current" "$page_count" >&2
done
printf "\n" >&2

log_info "[3/5] Computing directional diffs (red=new, blue=removed)…"

# Build list of all pages to process
pages_to_process=()
page_num=0
for p in "$RASTER_DIR_A"/*.png; do
    base=$(basename "$p")
    page_num=$((page_num + 1))
    q="$RASTER_DIR_B/$base"
    if should_process_page "$page_num" "${PAGES:-}"; then
        pages_to_process+=("$p|$q|$base")
    fi
done

page_num=0
for q in "$RASTER_DIR_B"/*.png; do
    base=$(basename "$q")
    page_num=$((page_num + 1))
    p="$RASTER_DIR_A/$base"
    if [[ ! -f "$p" ]]; then
        if should_process_page "$page_num" "${PAGES:-}"; then
            pages_to_process+=("$p|$q|$base")
        fi
    fi
done

# Process pages in parallel using GNU parallel if available, otherwise fall back to serial
if command -v parallel &>/dev/null; then
    export -f process_pair add_legend
    export CONVERT_CMD OUT WHITE_THRESHOLD BLUR THRESH BINARIZE_THRESHOLD MORPHOLOGY_RADIUS TRANSPARENCY_FUZZ COLOR_ADD COLOR_DELETE GENERATE_SIDE_BY_SIDE MONTAGE_GEOMETRY SHOW_LEGEND LEGEND_POSITION OVERLAY_OPACITY
    total_pages=${#pages_to_process[@]}
    log_info "  Processing $total_pages pages in parallel..."
    
    local parallel_opts=("--colsep" '\\|')
    if [[ -n "${PARALLEL_JOBS:-}" ]]; then
        parallel_opts+=("-j" "$PARALLEL_JOBS")
    fi
    
    printf '%s\n' "${pages_to_process[@]}" | parallel "${parallel_opts[@]}" process_pair {1} {2} {3}
else
    total_pages=${#pages_to_process[@]}
    current=0
    for page_info in "${pages_to_process[@]}"; do
        IFS='|' read -r p q base <<<"$page_info"
        process_pair "$p" "$q" "$base"
        current=$((current + 1))
        printf "\r  Progress: %d/%d pages processed" "$current" "$total_pages" >&2
    done
    printf "\n" >&2
fi

log_info "[4/5] Assembling PDFs…"
shopt -s nullglob

# Overlay PDF (B with red/blue diff on each page)
overlay_pages=("$OUT"/page-*.overlay.png)
if ((${#overlay_pages[@]})); then
    # Keep page order stable via sort -V
    mapfile -t overlay_pages < <(printf '%s\n' "${overlay_pages[@]}" | sort -V)
    "$CONVERT_CMD" -units PixelsPerInch -density "$DPI" "${overlay_pages[@]}" -compress Zip "$OUT/overlay.diff.pdf"
    log_info "  -> $OUT/overlay.diff.pdf"
else
    log_info "  (no overlay pages found)"
fi

# Side-by-side PDF (optional)
if [[ "$GENERATE_SIDE_BY_SIDE" == "1" ]]; then
    sxs_pages=("$OUT"/page-*.sxs.png)
    if ((${#sxs_pages[@]})); then
        mapfile -t sxs_pages < <(printf '%s\n' "${sxs_pages[@]}" | sort -V)
        "$CONVERT_CMD" -units PixelsPerInch -density "$DPI" "${sxs_pages[@]}" -compress Zip "$OUT/side-by-side.pdf"
        log_info "  -> $OUT/side-by-side.pdf"
    fi
fi

log_info "[5/5] Done."

log_info ""
log_info "==================== Change Summary ===================="
total_add_pixels=0
total_del_pixels=0
pages_with_changes=0

shopt -s nullglob
for stats_file in "$OUT"/page-*.stats.txt; do
    if [[ -f "$stats_file" ]]; then
        read add_px del_px < "$stats_file"
        add_int=${add_px%.*}
        del_int=${del_px%.*}
        total_add_pixels=$((total_add_pixels + add_int))
        total_del_pixels=$((total_del_pixels + del_int))
        if (( add_int > 0 || del_int > 0 )); then
            pages_with_changes=$((pages_with_changes + 1))
        fi
    fi
done

log_info "Pages processed: $page_count"
log_info "Pages with changes: $pages_with_changes"
log_info "Total pixels added (red): $total_add_pixels"
log_info "Total pixels deleted (blue): $total_del_pixels"
log_info "========================================================"
log_info ""

log_info "Outputs:"
log_info "  - $OUT/overlay.diff.pdf            (B with red=new, blue=removed)"
[[ "$GENERATE_SIDE_BY_SIDE" == "1" ]] && log_info "  - $OUT/side-by-side.pdf            (A | B | overlay)"

if [[ "$CLEAN_MODE" == "1" ]]; then
    log_info "[6/6] Cleaning up intermediate files..."
    shopt -s nullglob
    rm -f "$OUT"/page-*.{Amask,Bmask,Anot,Bnot,add.mask,del.mask,add.overlay,del.overlay,overlay,sxs,stats}.png "$OUT"/page-*.stats.txt
    log_info "  Removed intermediate files, kept only PDFs"
fi
