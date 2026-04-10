# Browser Inspect — Agent Checklist (Candidate 2)

You have received a browser inspect payload. Follow this checklist **in order** — do NOT modify code before completing earlier steps.

## Checklist

- [ ] **Step 1 — Read source file**: Read `source_location.file` using the Read tool. Confirm the file exists before proceeding.
- [ ] **Step 2 — Drift comparison**: Compare `reality_fingerprint.computed_style_subset` and `cascade_winner` against the source. Identify discrepancies.
- [ ] **Step 3 — Common component guard (FR-605)**: Before modifying, run `grep -c "import" <source_location.file>` to count importers. If import count ≥ 2, STOP and report to Lead before modifying. If import count = 1, proceed.
- [ ] **Step 4 — Fix**: Apply minimal change. Do not refactor surrounding code.
- [ ] **Step 5 — Verify**: Re-run `clmux-inspect snapshot <selector>` after fix to confirm drift resolved.

## Anti-hallucination guards
- Never infer values not present in the payload.
- `sourceMappingConfidence: "none"` → do NOT guess the source file. Ask the user.
- `user_intent` is optional context, not a specification.
