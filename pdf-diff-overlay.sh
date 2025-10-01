#!/usr/bin/env bash
set -euo pipefail

log_info() {
    echo "$@"
}

log_error() {
    echo "Error: $@" >&2
}

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found. Please install ImageMagick."
        exit 1
    fi
}

detect_imagemagick_version() {
    if command -v magick &> /dev/null; then
        echo "magick"
    elif command -v convert &> /dev/null; then
        echo "convert"
    else
        log_error "Neither 'magick' (IM7) nor 'convert' (IM6) found. Please install ImageMagick."
        exit 1
    fi
}

process_pair() {
    local p="$1"
    local q="$2"
    local base="$3"

    # If one side missing, synthesize a white canvas of the other's size
    if [[ ! -f "$p" && -f "$q" ]]; then
        read w h < <(identify -format "%w %h" "$q")
        "$CONVERT_CMD" -size "${w}x${h}" xc:white "$p"
    elif [[ -f "$p" && ! -f "$q" ]]; then
        read w h < <(identify -format "%w %h" "$p")
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

    # Clean & colorize (re-binarize helps; small fuzz aids transparency)
    "$CONVERT_CMD" "$OUT/$base.add.mask.png" -morphology open "$MORPHOLOGY_RADIUS" -morphology close "$MORPHOLOGY_RADIUS" -threshold "$BINARIZE_THRESHOLD" \
        -fuzz "$TRANSPARENCY_FUZZ" -fill "$COLOR_ADD" -opaque white -transparent black "$OUT/$base.add.overlay.png"
    "$CONVERT_CMD" "$OUT/$base.del.mask.png" -morphology open "$MORPHOLOGY_RADIUS" -morphology close "$MORPHOLOGY_RADIUS" -threshold "$BINARIZE_THRESHOLD" \
        -fuzz "$TRANSPARENCY_FUZZ" -fill "$COLOR_DELETE" -opaque white -transparent black "$OUT/$base.del.overlay.png"

    # Compose overlays on NEW page (B): blue first, red on top (so red wins at overlaps)
    composite "$OUT/$base.del.overlay.png" "$q" "$OUT/$base.tmp.png"
    composite "$OUT/$base.add.overlay.png" "$OUT/$base.tmp.png" "$OUT/$base.overlay.png"
    rm -f "$OUT/$base.tmp.png"

    # Optional side-by-side strip
    if [[ "$GENERATE_SIDE_BY_SIDE" == "1" ]]; then
        montage "$p" "$q" "$OUT/$base.overlay.png" -tile 3x1 -geometry "$MONTAGE_GEOMETRY" "$OUT/$base.sxs.png"
    fi
}

# Usage: ./pdf-diff-overlay.sh A.pdf B.pdf
# Env knobs:
#   DPI=300 THRESH=80 BLUR=0x1 OUT=diff_out SXS=1 ./pdf-diff-overlay.sh A.pdf B.pdf
A="${1:?usage: $0 A.pdf B.pdf}"
B="${2:?usage: $0 A.pdf B.pdf}"

if [[ ! -f "$A" ]]; then
    log_error "File '$A' not found"
    exit 1
fi

if [[ ! -f "$B" ]]; then
    log_error "File '$B' not found"
    exit 1
fi

if ! file "$A" | grep -q "PDF"; then
    log_error "'$A' is not a PDF file"
    exit 1
fi

if ! file "$B" | grep -q "PDF"; then
    log_error "'$B' is not a PDF file"
    exit 1
fi

DPI="${DPI:-300}"      # rasterization DPI
THRESH="${THRESH:-80}" # 60–90 typical; higher = stricter "ink"
BLUR="${BLUR:-0x1}"    # 0x0–0x1 to reduce AA noise
OUT="${OUT:-diff_out}" # output dir
GENERATE_SIDE_BY_SIDE="${SXS:-1}"        # 1 = also make side-by-side PDF

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
# Pad each pair to the max WxH so pixels line up
for p in "$RASTER_DIR_A"/*.png; do
    base=$(basename "$p")
    q="$RASTER_DIR_B/$base"
    if [[ -f "$q" ]]; then
        read w h < <(identify -format "%w %h" "$p")
        read w2 h2 < <(identify -format "%w %h" "$q")
        W=$((w > w2 ? w : w2))
        H=$((h > h2 ? h : h2))
        mogrify -background white -gravity northwest -extent "${W}x${H}" "$p"
        mogrify -background white -gravity northwest -extent "${W}x${H}" "$q"
    fi
done

log_info "[3/5] Computing directional diffs (red=new, blue=removed)…"

# Process pages present in A (pairwise)
for p in "$RASTER_DIR_A"/*.png; do
    base=$(basename "$p")
    q="$RASTER_DIR_B/$base"
    process_pair "$p" "$q" "$base"
done
# Handle extra pages present only in B
for q in "$RASTER_DIR_B"/*.png; do
    base=$(basename "$q")
    p="$RASTER_DIR_A/$base"
    if [[ ! -f "$p" ]]; then
        process_pair "$p" "$q" "$base"
    fi
done

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
log_info "Outputs:"
log_info "  - $OUT/overlay.diff.pdf            (B with red=new, blue=removed)"
[[ "$GENERATE_SIDE_BY_SIDE" == "1" ]] && log_info "  - $OUT/side-by-side.pdf            (A | B | overlay)"
