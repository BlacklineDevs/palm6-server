# 19-RFC - Request for Comment

This is the home for **RFCs** (Request for Comment) referenced throughout the Palm6
Creative System. Non-trivial creative, brand, structural, or governance changes are
proposed here before they are made, then recorded in the Decision Log once resolved.

## When an RFC is required

- Changing an approved brand element, folder structure, or governance rule.
- Introducing or changing metadata / naming standards.
- Promoting any asset toward **Approved** status (which is a prerequisite for the
  Vault, `15-VAULT/`).
- Anything the Quality Standards or Design Review Checklist flag as non-trivial.

Small, additive, reversible changes (e.g. copying approved docs, fixing typos) do
**not** need an RFC - but they should still be logged in the Decision Log if significant.

## Process

1. Copy `RFC-TEMPLATE.md` to `RFC-XXX-short-title.md` (next free number).
2. Fill it in and circulate for comment.
3. On resolution, record the outcome as a Decision Log entry in
   `00-FOUNDATION/DECISION-LOG/` (status Approved / Rejected / Deferred).
4. Only after an **Approved** decision may the change be treated as final, and only
   then may an asset move to `15-VAULT/`.

## Status

Phase 2 complete. `RFC-001-resource-and-asset-metadata-standard.md` is filed here and
**Approved** (adopted via DEC-003) - the resource/asset metadata standard. New RFCs
continue from RFC-002.
