#!/usr/bin/env bash
# Generate the styled participant HTML, DOCX, and PDF from canonical Markdown.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/docs/PARTICIPANT_GUIDE.md"
OUT="${ROOT}/docs/generated"
BASE="${OUT}/Packmate_Participant_Guide"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v libreoffice >/dev/null 2>&1 || { echo "ERROR: LibreOffice is required for DOCX/PDF generation" >&2; exit 1; }
mkdir -p "${OUT}"

python3 "${ROOT}/scripts/generate-participant-guide.py" "${SOURCE}" "${BASE}.html" >/dev/null

office_profile="$(mktemp -d)"
cleanup() { rm -rf "${office_profile}"; }
trap cleanup EXIT
profile_uri="file://${office_profile}"

libreoffice -env:UserInstallation="${profile_uri}" --headless \
  --convert-to 'docx:Office Open XML Text' --outdir "${OUT}" "${BASE}.html" >/tmp/packmate-guide-docx.log 2>&1 \
  || { cat /tmp/packmate-guide-docx.log >&2; exit 1; }
python3 "${ROOT}/scripts/embed-docx-images.py" "${BASE}.docx" >>/tmp/packmate-guide-docx.log
if command -v google-chrome >/dev/null 2>&1; then
  chrome_dir="$(mktemp -d)"
  chrome_pdf="${chrome_dir}/Packmate_Participant_Guide.pdf"
  google-chrome --headless --no-sandbox --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="${chrome_pdf}" "file://${BASE}.html" >/tmp/packmate-guide-pdf.log 2>&1 || true
  if [[ -s "${chrome_pdf}" ]]; then
    install -m 644 "${chrome_pdf}" "${BASE}.pdf"
  else
    libreoffice -env:UserInstallation="${profile_uri}" --headless \
      --convert-to pdf --outdir "${OUT}" "${BASE}.html" >>/tmp/packmate-guide-pdf.log 2>&1 \
      || { cat /tmp/packmate-guide-pdf.log >&2; exit 1; }
  fi
  rm -rf "${chrome_dir}"
else
  libreoffice -env:UserInstallation="${profile_uri}" --headless \
    --convert-to pdf --outdir "${OUT}" "${BASE}.html" >/tmp/packmate-guide-pdf.log 2>&1 \
    || { cat /tmp/packmate-guide-pdf.log >&2; exit 1; }
fi

[[ -s "${BASE}.docx" ]] || { echo "ERROR: DOCX was not generated" >&2; exit 1; }
[[ -s "${BASE}.pdf" ]] || { echo "ERROR: PDF was not generated" >&2; exit 1; }

bash "${ROOT}/scripts/validate-participant-guide.sh"

printf 'GUIDE_HTML %s\n' "${BASE}.html"
printf 'GUIDE_DOCX %s\n' "${BASE}.docx"
printf 'GUIDE_PDF  %s\n' "${BASE}.pdf"
