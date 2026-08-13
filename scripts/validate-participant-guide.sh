#!/usr/bin/env bash
# Offline structural checks for participant source and generated guide artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/docs/PARTICIPANT_GUIDE.md"
BASE="${ROOT}/docs/generated/Packmate_Participant_Guide"

python3 - "${SOURCE}" "${ROOT}/Makefile" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
makefile = Path(sys.argv[2]).read_text(encoding="utf-8")

expected = ["# Start here"] + [f"# MODULE {i} —" for i in range(1, 10)] + [
    "# WORKSHOP COMPLETE",
    "# APPENDIX A — Participant troubleshooting",
    "# APPENDIX B — Participant command reference",
]
positions = []
for heading in expected:
    pos = source.find(heading)
    if pos < 0:
        raise SystemExit(f"missing required heading: {heading}")
    positions.append(pos)
if positions != sorted(positions):
    raise SystemExit("participant guide headings are out of order")

for forbidden in (
    r"MODULE 10",
    r"CURRENT CODE BEHAVIOR",
    r"CURRENT CODE REQUIREMENT",
    r"\brollback\b",
    r"CONFIRM_DEMO_BASELINE_RESET",
    r"python3?\s+-?\s*<<",
    r"sed\s+[^\n]*sandbox\.env",
):
    if re.search(forbidden, source, flags=re.I):
        raise SystemExit(f"forbidden legacy participant wording: {forbidden}")

targets = set()
for raw in makefile.splitlines():
    if not raw or raw[0].isspace() or ":" not in raw:
        continue
    left = raw.split(":", 1)[0]
    if "=" in left:
        continue
    targets.update(word for word in left.split() if re.fullmatch(r"[A-Za-z0-9_.-]+", word))
commands = set(re.findall(r"\bmake\s+([a-z][a-z0-9-]+)", source))
missing = sorted(commands - targets)
if missing:
    raise SystemExit(f"guide references missing Make targets: {', '.join(missing)}")

placeholder_count = source.count("[Screenshot required:")
if placeholder_count != 13:
    raise SystemExit(f"expected exactly 13 named current-sandbox placeholders, found {placeholder_count}")

screenshot_refs = re.findall(
    r"^!\[[^]]+]\((assets/screenshots/[^)]+\.png)\)$",
    source,
    flags=re.M,
)
if len(screenshot_refs) != 14 or len(set(screenshot_refs)) != 14:
    raise SystemExit("expected exactly 14 unique reused screenshot references")
for reference in screenshot_refs:
    screenshot = Path(sys.argv[1]).parent / reference
    if not screenshot.is_file():
        raise SystemExit(f"missing reused screenshot asset: {reference}")
    if screenshot.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"reused screenshot is not a PNG: {reference}")
print("PASS  participant source structure and commands")
PY

for extension in html docx pdf; do
  [[ -s "${BASE}.${extension}" ]] || { echo "FAIL  missing ${BASE}.${extension}" >&2; exit 1; }
done
printf 'PASS  generated HTML, DOCX, and PDF exist\n'

unzip -p "${BASE}.docx" word/document.xml 2>/dev/null \
  | grep -q 'WORKSHOP COMPLETE' || { echo "FAIL  DOCX completion heading missing" >&2; exit 1; }
unzip -p "${BASE}.docx" word/document.xml 2>/dev/null \
  | grep -q 'APPENDIX B' || { echo "FAIL  DOCX Appendix B missing" >&2; exit 1; }
docx_images="$(unzip -Z1 "${BASE}.docx" 'word/media/*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "${docx_images}" =~ ^[0-9]+$ && "${docx_images}" -ge 14 ]] \
  || { echo "FAIL  expected reused screenshots embedded in DOCX; found ${docx_images:-0}" >&2; exit 1; }
if unzip -p "${BASE}.docx" word/_rels/document.xml.rels 2>/dev/null | grep -q 'TargetMode="External"'; then
  echo "FAIL  DOCX contains externally linked screenshots" >&2
  exit 1
fi
printf 'PASS  DOCX contains completion, appendices, and %s embedded images\n' "${docx_images}"

if command -v pdfinfo >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1; then
  pages="$(pdfinfo "${BASE}.pdf" | sed -n 's/^Pages:[[:space:]]*//p')"
  [[ "${pages}" =~ ^[0-9]+$ && "${pages}" -ge 15 ]] \
    || { echo "FAIL  unexpected PDF page count: ${pages:-unknown}" >&2; exit 1; }
  text_file="$(mktemp)"
  pdftotext -layout "${BASE}.pdf" "${text_file}"
  grep -q 'MODULE 9' "${text_file}" || { echo "FAIL  PDF Module 9 missing" >&2; exit 1; }
  grep -q 'APPENDIX A' "${text_file}" || { echo "FAIL  PDF Appendix A missing" >&2; exit 1; }
  grep -q 'APPENDIX B' "${text_file}" || { echo "FAIL  PDF Appendix B missing" >&2; exit 1; }
  if grep -Eqi '\brollback\b|MODULE 10|CURRENT CODE' "${text_file}"; then
    echo "FAIL  PDF contains legacy workshop wording" >&2
    exit 1
  fi
  python3 - "${text_file}" <<'PY'
import sys
from pathlib import Path

pages = Path(sys.argv[1]).read_text(errors="replace").split("\f")
for number, page in enumerate(pages, 1):
    lines = [line.strip() for line in page.splitlines() if line.strip()]
    for index, line in enumerate(lines):
        if line.startswith("MODULE ") and index >= len(lines) - 3:
            raise SystemExit(f"module heading stranded near bottom of PDF page {number}: {line}")
print("PASS  PDF headings are not obviously stranded")
PY
  rm -f "${text_file}"
  printf 'PASS  PDF text and page count (%s pages)\n' "${pages}"
fi

printf 'validate-guide: OK\n'
