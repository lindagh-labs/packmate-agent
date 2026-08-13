# Generated participant guide specification

The canonical participant prose is `docs/PARTICIPANT_GUIDE.md`.

Run:

```bash
make guide
```

This repository-native workflow produces:

- `docs/generated/Packmate_Participant_Guide.html`
- `docs/generated/Packmate_Participant_Guide.docx`
- `docs/generated/Packmate_Participant_Guide.pdf`

The generator uses only repository source, repository screenshot assets, locally installed LibreOffice and, when available, headless Chrome for the final PDF print. It does not download fonts, screenshots, templates, or participant data.

## Document order

1. Cover
2. Start here
3. Module 1 — RHDP sandbox and GitHub fork
4. Module 2 — OpenShift AI project and Workbench
5. Module 3 — Participant workspace and Git fork
6. Module 4 — GitOps, registry access and bootstrap
7. Module 5 — OpenShift AI Playground
8. Module 6 — DEV application
9. Module 7 — Tekton Pipeline
10. Module 8 — Git promotion
11. Module 9 — PROD synchronization and validation
12. Workshop complete
13. Appendix A — Participant troubleshooting
14. Appendix B — Participant command reference

## Visual language

- white page background;
- black headings with Red Hat red rules and accents;
- light grey supporting panels;
- blue information and learning callouts;
- green success checkpoints;
- red warnings and stop checkpoints;
- dark terminal blocks with wrapped monospace text.

Module headings are kept with the content that follows and use a strong red section rule. Content flows continuously so a final checkpoint is not stranded on an otherwise empty page. Heading groups, figures, and table rows avoid bad page breaks where the output format supports them. Approved screenshots are losslessly cropped repository PNGs. Missing current evidence appears as a grey, specifically named placeholder; the generator never invents images.

## Screenshot evidence

The source reuses 14 screenshots from the prior participant DOCX after module-by-module verification. The extraction, crop, caption, and rejection decisions are recorded in `docs/SCREENSHOT_REUSE_AUDIT.md`.

The 13 current-sandbox placeholders are:

1. `packmate-workbench` Running and ready to open
2. Repository open in code-server
3. Packmate Llama model asset in `packmate-lab` with current readiness state
4. System instructions
5. Weather MCP tool call
6. Baggage MCP tool call
7. Successful PipelineRun seven-task graph
8. AI quality gate PASS
9. Candidate image digest
10. Promotion pull request
11. Argo CD OutOfSync
12. Argo CD Synced and Healthy
13. PROD application response after verification

## Validation

`make guide` finishes by running `make validate-guide`. Validation checks module order, required appendices, forbidden legacy wording, screenshot asset references, named placeholder count, generated file presence, embedded DOCX images, document text, page count, and obvious stranded module headings. Placeholders still require an instructor smoke run on an RHDP sandbox.
