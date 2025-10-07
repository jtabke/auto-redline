# auto-redline

Automatic PDF redline generator that compares two PDF files and produces visual diff outputs highlighting additions and deletions.

## Features

- **Visual Diff Overlay**: Generates a redlined PDF showing additions in red and deletions in blue
- **Side-by-Side Comparison**: Optional 3-panel view (Original A | Original B | Overlay)
- **Page Count Differences**: Handles PDFs with different page counts
- **Configurable Processing**: Adjustable DPI, thresholds, and blur settings

## Requirements

- **ImageMagick 6 or 7** (`convert`, `composite`, `montage`, `mogrify`, `identify`)
  - ImageMagick is licensed under the [ImageMagick License](https://imagemagick.org/script/license.php)
  - For ImageMagick 7, replace `convert` with `magick` in the script (lines 22-23)
- **GNU Parallel** (optional, recommended for multi-page PDFs)
  - Automatically used if available for processing multiple pages concurrently
  - Single-page PDFs always use sequential processing (faster due to less overhead)
- Bash 4.0+

## Installation

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install imagemagick parallel
```

### Fedora/RHEL/CentOS

```bash
sudo dnf install ImageMagick parallel
```

### macOS

```bash
brew install imagemagick parallel
```

### Arch Linux

```bash
sudo pacman -S imagemagick parallel
```

### Verify Installation

Check that ImageMagick is installed correctly:

```bash
convert -version
```

You should see ImageMagick version information. For ImageMagick 7, use:

```bash
magick -version
```

### Make Script Executable

```bash
chmod +x auto-redline.sh
```

## Usage

### Basic Usage

```bash
./auto-redline.sh A.pdf B.pdf
```

This compares `A.pdf` (old version) with `B.pdf` (new version) and outputs:

- `diff_out/overlay.diff.pdf` - B with red additions and blue deletions
- `diff_out/side-by-side.pdf` - Three-panel comparison

### Advanced Usage with Environment Variables

```bash
DPI=300 THRESH=80 BLUR=0x1 OUT=custom_output SXS=1 ./auto-redline.sh old.pdf new.pdf
```

## Configuration

| Variable             | Default      | Description                                                      |
| -------------------- | ------------ | ---------------------------------------------------------------- |
| `DPI`                | 300          | Rasterization DPI (higher = better quality, slower)              |
| `THRESH`             | 80           | Threshold for detecting "ink" (60-90 typical; higher = stricter) |
| `BLUR`               | 0x1          | Gaussian blur to reduce anti-aliasing noise (0x0 to 0x2)         |
| `OUT`                | diff_out     | Output directory for all generated files                         |
| `SXS`                | 1            | Generate side-by-side PDF (1=yes, 0=no)                          |
| `SHOW_LEGEND`        | 1            | Show color legend on overlay PDF (1=yes, 0=no)                   |
| `LEGEND_POSITION`    | bottom-right | Legend position: top-left, top-right, bottom-left, bottom-right  |
| `OVERLAY_OPACITY`    | 100          | Overlay transparency: 0-100 (0=invisible, 100=opaque)            |
| `PAGES`              | all          | Page range to process: "1-5,10,15-20" (processes specific pages) |
| `PARALLEL_JOBS`      | auto         | Number of parallel jobs (e.g., 4, 8, or "auto" for CPU count)    |
| `KEEP_INTERMEDIATES` | 0            | Keep all intermediate processing files (1=yes, 0=no)             |

## Output Files

### Main Outputs

- `{OUT}/overlay.diff.pdf` - Final redlined PDF with B as base, showing:
  - **Red**: Content added in B (not in A)
  - **Blue**: Content removed from A (not in B)
- `{OUT}/side-by-side.pdf` - Three-panel view per page: A | B | Overlay

### Intermediate Files

The output directory contains per-page intermediate files:

- `page-{N}.Amask.png` / `page-{N}.Bmask.png` - Binary ink masks
- `page-{N}.add.mask.png` / `page-{N}.del.mask.png` - Addition/deletion masks
- `page-{N}.add.overlay.png` / `page-{N}.del.overlay.png` - Colorized overlays
- `page-{N}.overlay.png` - Final composite overlay per page
- `page-{N}.sxs.png` - Side-by-side composite per page

## Processing Pipeline

1. **Rasterization** - Converts both PDFs to PNG images at specified DPI
2. **Canvas Normalization** - Pads each page pair to matching dimensions
3. **Diff Computation** - Creates binary masks and computes set differences:
   - Additions: B ∖ A (content in B but not in A)
   - Deletions: A ∖ B (content in A but not in B)
4. **Colorization** - Applies red/blue coloring with morphological cleanup
5. **Assembly** - Combines processed pages back into PDF format

**Performance**: Multi-page PDFs are automatically processed in parallel using GNU parallel if available (approximately 27% faster on 3-page documents). Single-page PDFs always use sequential processing to avoid overhead.

## Tuning Tips

### Threshold Adjustment

- **Lower values (60-70)**: Detect lighter marks, but may pick up more noise
- **Higher values (85-95)**: Only detect darker "ink", cleaner but may miss faint text

### DPI Selection

- **150**: Fast, lower quality (suitable for drafts)
- **300**: Balanced quality and speed (default)
- **600**: High quality for detailed documents (slower)

### Blur Settings

- **0x0**: No blur, sharp but may show aliasing artifacts
- **0x1**: Light blur to reduce anti-aliasing noise (recommended)
- **0x2**: Heavier blur for very noisy scans

## Examples

### Compare legal documents at high quality

```bash
DPI=600 THRESH=85 ./auto-redline.sh contract_v1.pdf contract_v2.pdf
```

### Quick draft comparison without side-by-side

```bash
DPI=150 SXS=0 ./auto-redline.sh draft1.pdf draft2.pdf
```

### Process scanned documents with noise

```bash
THRESH=70 BLUR=0x2 ./auto-redline.sh scan_old.pdf scan_new.pdf
```

### Control parallel processing for large documents

```bash
# Limit to 4 parallel jobs to reduce memory usage
PARALLEL_JOBS=4 ./auto-redline.sh large_doc_v1.pdf large_doc_v2.pdf

# Process only specific pages
PAGES="1-5,10" ./auto-redline.sh doc_v1.pdf doc_v2.pdf
```

## Troubleshooting

### ImageMagick 7 Users

Change lines 22-23 from `convert` to `magick`:

```bash
magick -density "$DPI" ... "$A" "$RA/page-%05d.png"
magick -density "$DPI" ... "$B" "$RB/page-%05d.png"
```

### No differences detected

- Try lowering `THRESH` (e.g., 60-70)
- Check if PDFs are identical or only differ in metadata
- Increase `DPI` for better detection of small changes

### Too many false positives

- Increase `THRESH` (e.g., 85-95)
- Increase `BLUR` (e.g., 0x1.5 or 0x2)
- Ensure PDFs are vector-based, not scanned images

### Memory issues with large PDFs

- Reduce `DPI` (e.g., 150 or 200)
- Process subsets of pages manually
- Increase available system memory

## License

This tool requires ImageMagick as an external dependency. ImageMagick is licensed under the [ImageMagick License](https://imagemagick.org/script/license.php). Users must install ImageMagick separately according to its license terms.
