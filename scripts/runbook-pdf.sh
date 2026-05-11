#!/usr/bin/env bash
# Render every runbook/*.md to a 8.5" x 5.5" PDF.
#   Paper: 8.5"x5.5" landscape, 0.5" margins, 10pt body, page numbers.
#   Each doc: title page (extracted from first H1) + TOC.
# Pipeline: pandoc (markdown -> typst) + typst (typeset -> PDF).
# Output: runbook/<name>.pdf, gitignored via /runbook/*.pdf in .gitignore.
# Run: `pnpm pdf` or `bash scripts/runbook-pdf.sh`.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."   # repo root
runbook_dir="runbook"

for tool in pandoc typst; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool. Install via pacman."; exit 1; }
done

template=$(mktemp --suffix=.typ)
trap 'rm -f "$template"' EXIT

cat > "$template" <<'TYPST'
// --- Pandoc helpers (kept from the default typst template) ---
#let horizontalrule = line(start: (25%, 0%), end: (75%, 0%))

#show terms: it => {
  it.children
    .map(child => [
      #strong[#child.term]
      #block(inset: (left: 1.5em, top: -0.4em))[#child.description]
    ])
    .join()
}

#set table(inset: 6pt, stroke: 0.5pt + luma(180))
#show table: set text(size: 0.92em)

// --- Page setup: 8.5x5.5 landscape, 0.5" margins, page numbers centered ---
#set page(
  width: 8.5in,
  height: 5.5in,
  margin: 0.5in,
  numbering: "1",
  number-align: center,
)

// --- Body text ---
#set text(
  size: $if(fontsize)$$fontsize$$else$10pt$endif$,
)
#set par(justify: false, leading: 0.55em, first-line-indent: 0pt)

// --- Headings ---
#show heading.where(level: 1): it => block(below: 0.7em, above: 1.3em)[
  #set text(weight: "bold", size: 1.5em)
  #it.body
]
#show heading.where(level: 2): it => block(below: 0.5em, above: 1.1em)[
  #set text(weight: "bold", size: 1.2em)
  #it.body
]
#show heading.where(level: 3): it => block(below: 0.3em, above: 0.8em)[
  #set text(weight: "bold", size: 1.05em)
  #it.body
]

// --- Code blocks ---
#show raw.where(block: true): it => block(
  fill: luma(245),
  inset: (x: 8pt, y: 6pt),
  radius: 2pt,
  width: 100%,
  breakable: true,
)[#set text(size: 0.85em); #it]

#show raw.where(block: false): it => box(
  fill: luma(240),
  inset: (x: 2pt, y: 0pt),
  outset: (y: 2pt),
  radius: 1pt,
)[#it]

#show heading: it => block(it, breakable: false)

$for(header-includes)$
$header-includes$

$endfor$

$if(title)$
// --- Title page (unnumbered) ---
#page(numbering: none, margin: 0.5in)[
  #set align(center + horizon)
  #text(26pt, weight: "bold")[$title$]
  $if(subtitle)$
  #v(0.8em)
  #text(14pt, style: "italic")[$subtitle$]
  $endif$
  $if(date)$
  #v(2em)
  #text(11pt)[$date$]
  $endif$
]
$endif$

$if(toc)$
// --- TOC pages numbered with roman numerals ---
#set page(numbering: "i")
#counter(page).update(1)
#outline(
  title: [Contents],
  depth: $if(toc-depth)$$toc-depth$$else$2$endif$,
  indent: auto,
)
#pagebreak()
#set page(numbering: "1")
#counter(page).update(1)
$endif$

$body$
TYPST

mapfile -t mds < <(find "$runbook_dir" -maxdepth 1 -name '*.md' -type f | sort)
if [[ ${#mds[@]} -eq 0 ]]; then
  echo "No .md files in $runbook_dir"
  exit 1
fi

failures=0
for md in "${mds[@]}"; do
  out="${md%.md}.pdf"

  # Title: first H1 (sans "# "), or fall back to filename
  title=$(grep -m1 '^# ' "$md" 2>/dev/null | sed 's/^# *//' || true)
  if [[ -z "$title" ]]; then
    title=$(basename "${md%.md}")
  fi

  # Strip the first H1 from body so the title doesn't appear twice.
  body=$(mktemp --suffix=.md)
  sed '0,/^# /{/^# /d;}' "$md" > "$body"

  echo ">> $md -> $out"
  # `-citations`: btrfs subvol names like `@home`/`@swap` aren't bibliography keys.
  if pandoc "$body" -o "$out" \
      --from=markdown-citations \
      --pdf-engine=typst \
      --template="$template" \
      --toc --toc-depth=2 \
      -V fontsize=10pt \
      -M title="$title" 2>&1; then
    :
  else
    echo "  FAIL $md"
    failures=$((failures + 1))
  fi
  rm -f "$body"
done

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "Generated:"
ls -lh "$runbook_dir"/*.pdf
