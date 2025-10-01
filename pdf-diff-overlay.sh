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
SXS="${SXS:-1}"        # 1 = also make side-by-side PDF

check_dependency convert
check_dependency composite
check_dependency montage
check_dependency mogrify
check_dependency identify

RA="__ra"
RB="__rb"
mkdir -p "$OUT" "$RA" "$RB"

log_info "[1/5] Rasterizing PDFs at ${DPI} DPI…"
# IM6 'convert'; for IM7 use 'magick' instead of 'convert'
convert -density "$DPI" -units PixelsPerInch -background white -alpha remove -alpha off -colorspace sRGB "$A" "$RA/page-%05d.png"
convert -density "$DPI" -units PixelsPerInch -background white -alpha remove -alpha off -colorspace sRGB "$B" "$RB/page-%05d.png"

log_info "[2/5] Normalizing canvas sizes page-by-page…"
# Pad each pair to the max WxH so pixels line up
for p in "$RA"/*.png; do
    base=$(basename "$p")
    q="$RB/$base"
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
# Helper to build masks, boolean math, colorize, and overlay
process_pair() {
    local p="$1" # A page png (may be missing)
    local q="$2" # B page png (may be missing)
    local base="$3"

    # If one side missing, synthesize a white canvas of the other’s size
    if [[ ! -f "$p" && -f "$q" ]]; then
        read w h < <(identify -format "%w %h" "$q")
        convert -size "${w}x${h}" xc:white "$p"
    elif [[ -f "$p" && ! -f "$q" ]]; then
        read w h < <(identify -format "%w %h" "$p")
        convert -size "${w}x${h}" xc:white "$q"
    elif [[ ! -f "$p" && ! -f "$q" ]]; then
        return 0
    fi

    # Binary "ink" masks (white where ink is)
    convert "$p" -colorspace gray -white-threshold 95% -blur "$BLUR" -threshold "${THRESH}%" -negate -type bilevel "$OUT/$base.Amask.png"
    convert "$q" -colorspace gray -white-threshold 95% -blur "$BLUR" -threshold "${THRESH}%" -negate -type bilevel "$OUT/$base.Bmask.png"

    # additions = B∖A = B & !A  (boolean via Multiply; no alpha tricks)
    convert "$OUT/$base.Amask.png" -negate "$OUT/$base.Anot.png"
    convert "$OUT/$base.Bmask.png" "$OUT/$base.Anot.png" -compose Multiply -composite "$OUT/$base.add.mask.png"

    # deletions = A∖B = A & !B
    convert "$OUT/$base.Bmask.png" -negate "$OUT/$base.Bnot.png"
    convert "$OUT/$base.Amask.png" "$OUT/$base.Bnot.png" -compose Multiply -composite "$OUT/$base.del.mask.png"

    # Clean & colorize (re-binarize helps; small fuzz aids transparency)
    convert "$OUT/$base.add.mask.png" -morphology open disk:1 -morphology close disk:1 -threshold 50% \
        -fuzz 1% -fill red -opaque white -transparent black "$OUT/$base.add.overlay.png"
    convert "$OUT/$base.del.mask.png" -morphology open disk:1 -morphology close disk:1 -threshold 50% \
        -fuzz 1% -fill blue -opaque white -transparent black "$OUT/$base.del.overlay.png"

    # Compose overlays on NEW page (B): blue first, red on top (so red wins at overlaps)
    composite "$OUT/$base.del.overlay.png" "$q" "$OUT/$base.tmp.png"
    composite "$OUT/$base.add.overlay.png" "$OUT/$base.tmp.png" "$OUT/$base.overlay.png"
    rm -f "$OUT/$base.tmp.png"

    # Optional side-by-side strip
    if [[ "$SXS" == "1" ]]; then
        montage "$p" "$q" "$OUT/$base.overlay.png" -tile 3x1 -geometry +12+12 "$OUT/$base.sxs.png"
    fi
}

# Process pages present in A (pairwise)
for p in "$RA"/*.png; do
    base=$(basename "$p")
    q="$RB/$base"
    process_pair "$p" "$q" "$base"
done
# Handle extra pages present only in B
for q in "$RB"/*.png; do
    base=$(basename "$q")
    p="$RA/$base"
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
    convert -units PixelsPerInch -density "$DPI" "${overlay_pages[@]}" -compress Zip "$OUT/overlay.diff.pdf"
    log_info "  -> $OUT/overlay.diff.pdf"
else
    log_info "  (no overlay pages found)"
fi

# Side-by-side PDF (optional)
if [[ "$SXS" == "1" ]]; then
    sxs_pages=("$OUT"/page-*.sxs.png)
    if ((${#sxs_pages[@]})); then
        mapfile -t sxs_pages < <(printf '%s\n' "${sxs_pages[@]}" | sort -V)
        convert -units PixelsPerInch -density "$DPI" "${sxs_pages[@]}" -compress Zip "$OUT/side-by-side.pdf"
        log_info "  -> $OUT/side-by-side.pdf"
    fi
fi

log_info "[5/5] Done."
log_info "Outputs:"
log_info "  - $OUT/overlay.diff.pdf            (B with red=new, blue=removed)"
[[ "$SXS" == "1" ]] && log_info "  - $OUT/side-by-side.pdf            (A | B | overlay)"
