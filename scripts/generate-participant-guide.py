#!/usr/bin/env python3
"""Render the Packmate participant Markdown into styled HTML."""

from __future__ import annotations

import argparse
import html
import os
import re
from pathlib import Path


def inline(text: str) -> str:
    escaped = html.escape(text, quote=False)
    code: list[str] = []

    def save_code(match: re.Match[str]) -> str:
        code.append(f"<code>{match.group(1)}</code>")
        return f"\x00CODE{len(code) - 1}\x00"

    escaped = re.sub(r"`([^`]+)`", save_code, escaped)
    escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(
        r"\[([^]]+)]\(([^)]+)\)",
        lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>',
        escaped,
    )
    for index, fragment in enumerate(code):
        escaped = escaped.replace(f"\x00CODE{index}\x00", fragment)
    return escaped


def parse_table(lines: list[str]) -> str:
    rows = []
    for line in lines:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rows.append(cells)
    header = rows[0]
    body = rows[2:]
    width_map = {
        ("ENV", "Namespace", "Purpose", "Deployment owner"): (22, 18, 35, 25),
        ("Symptom", "What it means", "Recovery"): (23, 27, 50),
        ("Command", "Purpose", "Safe to repeat"): (25, 55, 20),
        ("Scenario", "What to observe"): (38, 62),
        ("Playground prototype", "Industrialized DEV application"): (48, 52),
    }
    widths = width_map.get(tuple(header), tuple([100 // len(header)] * len(header)))
    columns = "".join(f'<col style="width:{width}%">' for width in widths)
    out = [
        f'<table style="width:100%;table-layout:fixed;border-collapse:collapse;margin:10px 0 18px"><colgroup>{columns}</colgroup><thead><tr>'
    ]
    out.extend(
        f'<th style="width:{widths[index]}%;background:#151515;color:#fff;text-align:left;padding:7px;border:1px solid #4f5255">{inline(cell)}</th>'
        for index, cell in enumerate(header)
    )
    out.append("</tr></thead><tbody>")
    for row in body:
        out.append("<tr>")
        out.extend(
            f'<td style="width:{widths[index]}%;vertical-align:top;padding:6px;border:1px solid #d2d2d2">{inline(cell)}</td>'
            for index, cell in enumerate(row)
        )
        out.append("</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def markdown_body(source: str, source_dir: Path, output_dir: Path) -> str:
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if line == "# Start here")
    lines = lines[start:]
    out: list[str] = []
    paragraph: list[str] = []
    index = 0

    def flush_paragraph() -> None:
        if not paragraph:
            return
        raw = " ".join(part.strip() for part in paragraph)
        css = ""
        upper = raw.upper()
        if upper.startswith("**REQUIRED RESULT:**") or upper.startswith("**REQUIRED EVIDENCE:**"):
            css = ' class="checkpoint success"'
        elif upper.startswith("**EXPECTED RESULT:**"):
            css = ' class="checkpoint expected"'
        if css:
            expected = "expected" in css
            color = "#0066cc" if expected else "#3e8635"
            background = "#e7f1fa" if expected else "#edf8eb"
            out.append(
                f'<table{css} role="presentation" style="width:100%;border-collapse:collapse;'
                f'margin:11px 0;page-break-inside:avoid"><tr><td style="padding:9px 13px;'
                f'border:0;border-left:5px solid {color};background:{background}">{inline(raw)}</td>'
                f'</tr></table>'
            )
        else:
            out.append(f"<p>{inline(raw)}</p>")
        paragraph.clear()

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if stripped.startswith("```"):
            flush_paragraph()
            language = stripped[3:].strip()
            index += 1
            content: list[str] = []
            while index < len(lines) and not lines[index].strip().startswith("```"):
                content.append(lines[index])
                index += 1
            label = language.upper() if language else "TERMINAL"
            out.append(
                f'<div class="code-label" style="background:#2b2d2f;color:#b8bbbe;'
                f'font-family:monospace;padding:7px 11px 2px">{html.escape(label)}</div>'
                f'<pre style="background:#151515;color:#f0f0f0;margin:0 0 15px;'
                f'padding:11px;white-space:pre-wrap"><code>{html.escape(chr(10).join(content))}</code></pre>'
            )
            index += 1
            continue

        if stripped.startswith("#"):
            flush_paragraph()
            level = len(stripped) - len(stripped.lstrip("#"))
            title = stripped[level:].strip()
            css = ""
            if level == 1:
                classes = ["section-heading"]
                if title == "WORKSHOP COMPLETE":
                    classes.append("completion-heading")
                css = f' class="{" ".join(classes)}"'
            heading_style = {
                1: "font-size:28px;line-height:1.12;margin:32px 0 20px;padding-bottom:9px;border-bottom:5px solid #ee0000;color:#151515;page-break-after:avoid",
                2: "font-size:19px;line-height:1.2;margin:25px 0 9px;page-break-after:avoid",
                3: "font-size:16px;margin:25px 0 8px;page-break-after:avoid",
            }.get(level, "")
            out.append(f'<h{level}{css} style="{heading_style}">{inline(title)}</h{level}>')
            index += 1
            continue

        if stripped.startswith(">"):
            flush_paragraph()
            quote: list[str] = []
            while index < len(lines) and lines[index].strip().startswith(">"):
                quote.append(lines[index].strip()[1:].strip())
                index += 1
            raw = " ".join(quote)
            upper = raw.upper()
            kind = "info"
            color = "#0066cc"
            background = "#e7f1fa"
            if "SECURITY" in upper or "WARNING" in upper or "STOP BEFORE CONTINUING" in upper:
                kind = "warning"
                color = "#c9190b"
                background = "#faeae8"
            elif "WHAT YOU WILL COMPLETE" in upper or "WHY THIS MATTERS" in upper:
                kind = "learning"
            out.append(
                f'<table class="callout {kind}" role="presentation" style="width:100%;'
                f'border-collapse:collapse;margin:11px 0 15px;page-break-inside:avoid"><tr>'
                f'<td style="padding:11px 15px;border:0;border-left:6px solid {color};'
                f'background:{background}">{inline(raw)}</td></tr></table>'
            )
            continue

        image_match = re.fullmatch(r"!\[([^]]+)]\(([^)]+)\)", stripped)
        if image_match:
            flush_paragraph()
            caption, raw_path = image_match.groups()
            image_path = (source_dir / raw_path).resolve()
            if not image_path.is_file():
                raise FileNotFoundError(f"guide screenshot not found: {image_path}")
            image_src = Path(os.path.relpath(image_path, output_dir)).as_posix()
            out.append(
                '<figure class="screenshot reused" style="margin:13px 0 17px;page-break-inside:avoid">'
                f'<img src="{html.escape(image_src, quote=True)}" alt="{html.escape(caption, quote=True)}" '
                'style="display:block;width:100%;height:auto;border:1px solid #d2d2d2" />'
                f'<figcaption style="color:#4f5255;font-size:11px;margin-top:6px">{inline(caption)}</figcaption></figure>'
            )
            index += 1
            continue

        if stripped.startswith("[") and stripped.endswith("]") and "Screenshot required:" in stripped:
            flush_paragraph()
            label = stripped[1:-1]
            subject = label.split(":", 1)[1].strip()
            out.append(
                '<figure class="screenshot" style="margin:13px 0 17px;page-break-inside:avoid">'
                '<table class="placeholder" role="presentation" style="width:100%;height:128px;'
                'border-collapse:collapse;margin:0;background:#f0f0f0;color:#6a6e73">'
                '<tr><td style="height:128px;border:2px dashed #929292;text-align:center;'
                f'vertical-align:middle;padding:18px;font-weight:bold">CURRENT SCREENSHOT NEEDED: {inline(subject)}</td></tr></table>'
                '</figure>'
            )
            index += 1
            continue

        if stripped.startswith("|") and index + 1 < len(lines) and re.match(
            r"^\|?\s*:?-+", lines[index + 1].strip()
        ):
            flush_paragraph()
            table_lines = [line, lines[index + 1]]
            index += 2
            while index < len(lines) and lines[index].strip().startswith("|"):
                table_lines.append(lines[index])
                index += 1
            out.append(parse_table(table_lines))
            continue

        if re.match(r"^[-*] ", stripped):
            flush_paragraph()
            items: list[str] = []
            while index < len(lines) and re.match(r"^\s*[-*] ", lines[index]):
                items.append(re.sub(r"^\s*[-*] ", "", lines[index]).strip())
                index += 1
            out.append("<ul>" + "".join(f"<li>{inline(item)}</li>" for item in items) + "</ul>")
            continue

        if re.match(r"^\d+\. ", stripped):
            flush_paragraph()
            items = []
            while index < len(lines) and re.match(r"^\s*\d+\. ", lines[index]):
                items.append(re.sub(r"^\s*\d+\. ", "", lines[index]).strip())
                index += 1
            out.append("<ol>" + "".join(f"<li>{inline(item)}</li>" for item in items) + "</ol>")
            continue

        if stripped in {"---", ""}:
            flush_paragraph()
            index += 1
            continue

        paragraph.append(stripped)
        index += 1

    flush_paragraph()
    return "\n".join(out)


CSS = r"""
@page { size: A4; margin: 15mm 15mm 17mm 15mm; }
@page:first { margin: 0; }
* { box-sizing: border-box; }
body { margin: 0; color: #151515; background: white; font-family: Arial, Helvetica, sans-serif; font-size: 9.5pt; line-height: 1.35; }
.cover { height: 297mm; padding: 33mm 24mm 24mm; position: relative; page-break-after: always; overflow: hidden; }
.cover-rule { width: 34mm; height: 4mm; background: #ee0000; margin-bottom: 24mm; }
.cover h1 { font-size: 34pt; line-height: 1.02; margin: 0 0 6mm; color: #151515; }
.cover .eyebrow { color: #6a6e73; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; margin-bottom: 5mm; }
.cover .journey { font-size: 17pt; line-height: 1.35; max-width: 145mm; margin: 15mm 0 12mm; }
.cover .meta { position: absolute; bottom: 28mm; left: 24mm; right: 24mm; border-top: 1px solid #d2d2d2; padding-top: 6mm; color: #4f5255; }
.red { color: #c9190b; }
.content { max-width: 178mm; margin: 0 auto; }
h1.section-heading { break-before: auto; break-after: avoid; page-break-after: avoid; font-size: 21pt; line-height: 1.12; margin: 9mm 0 6mm; padding-top: 1mm; border-bottom: 1.4mm solid #ee0000; padding-bottom: 2.5mm; color: #151515; }
h1.section-heading:first-child { margin-top: 0; }
h1.section-heading + .callout { break-before: avoid; page-break-before: avoid; }
h1.completion-heading + p + ul { columns: 2; column-gap: 9mm; font-size: 9pt; break-inside: avoid; page-break-inside: avoid; }
h2 { font-size: 14pt; line-height: 1.2; margin: 7mm 0 2.5mm; break-after: avoid; page-break-after: avoid; }
h3 { font-size: 12pt; margin: 7mm 0 2mm; break-after: avoid; }
p { margin: 0 0 2.8mm; orphans: 2; widows: 2; }
a { color: #0066cc; text-decoration: none; }
code { font-family: "Liberation Mono", Consolas, monospace; font-size: .92em; }
p code, li code, td code { background: #f0f0f0; padding: .3mm .8mm; border-radius: .8mm; overflow-wrap: anywhere; }
.code-label { background: #2b2d2f; color: #b8bbbe; font: 7.5pt "Liberation Mono", monospace; padding: 2mm 3mm 0; border-radius: 1.5mm 1.5mm 0 0; break-after: avoid; }
pre { background: #151515; color: #f0f0f0; margin: 0 0 4mm; padding: 3mm; border-radius: 0 0 1.5mm 1.5mm; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.32; break-inside: avoid; page-break-inside: avoid; }
pre code { font-size: 8.6pt; }
ul, ol { margin: 1mm 0 3mm 5mm; padding-left: 4.5mm; }
li { margin-bottom: .9mm; }
.callout { margin: 3mm 0 4mm; break-inside: avoid; page-break-inside: avoid; }
.checkpoint { margin: 3mm 0; break-inside: avoid; page-break-inside: avoid; }
table { width: 100%; border-collapse: collapse; margin: 2.5mm 0 4.5mm; font-size: 8pt; }
thead { display: table-header-group; }
tr { break-inside: avoid; page-break-inside: avoid; }
th { background: #151515; color: white; text-align: left; padding: 1.8mm; border: .25mm solid #4f5255; }
td { vertical-align: top; padding: 1.6mm; border: .25mm solid #d2d2d2; overflow-wrap: anywhere; }
tbody tr:nth-child(even) { background: #f5f5f5; }
.screenshot { margin: 3.5mm 0 4.5mm; break-inside: avoid; page-break-inside: avoid; }
.screenshot img { display: block; width: 100%; height: auto; max-height: 160mm; object-fit: contain; border: .25mm solid #d2d2d2; }
.placeholder { height: 34mm; border-collapse: collapse; background: #f0f0f0; color: #6a6e73; font-weight: 700; letter-spacing: .03em; }
.placeholder td { height: 34mm; border: .5mm dashed #929292; text-align: center; vertical-align: middle; padding: 4mm; }
figcaption { color: #4f5255; font-size: 8pt; margin-top: 1.5mm; }
strong { font-weight: 700; }
"""


def document(body: str) -> str:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Packmate Agent Participant Guide</title>
<style>{CSS}</style></head><body>
<section class="cover" style="page-break-after:always;padding:125px 91px 91px;position:relative">
  <div class="cover-rule" style="width:128px;height:15px;background:#ee0000;margin-bottom:91px"></div>
  <div class="eyebrow" style="color:#6a6e73;font-weight:bold;letter-spacing:1px;text-transform:uppercase;margin-bottom:19px">Red Hat Demo Platform · Beginner workshop</div>
  <h1 style="font-size:45px;line-height:1.02;margin:0 0 23px;color:#151515">Packmate<br><span class="red" style="color:#c9190b">Agent</span></h1>
  <div class="journey" style="font-size:23px;line-height:1.35;margin:57px 0 45px">From an OpenShift AI prototype to a reviewed, immutable, GitOps-managed production release.</div>
  <p><strong>OpenShift AI · MCP · React · FastAPI · Tekton · GHCR · Git · Argo CD</strong></p>
  <div style="height:120px"></div>
  <div class="meta" style="border-top:1px solid #d2d2d2;padding-top:23px;color:#4f5255">Participant guide<br>Estimated time: 150 minutes<br>Canonical source: Lindagh1/packmate-agent</div>
</section>
<p style="page-break-before:always;break-before:page;margin:0"></p>
<main class="content">{body}</main>
</body></html>"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.source.read_text(encoding="utf-8")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        document(markdown_body(source, args.source.parent.resolve(), args.output.parent.resolve())),
        encoding="utf-8",
    )
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
