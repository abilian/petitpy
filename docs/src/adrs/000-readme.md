# Architecture Decision Records (ADRs) for petitpy

An ADR records one architectural decision, with the context that prompted it and its consequences. The format follows [Michael Nygard's ADR sketch](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions), with some of [Python's PEP process](https://www.python.org/dev/peps/pep-0001/). The list of ADRs is in [`index.md`](index.md).

## Statuses

| Status | Meaning |
|---|---|
| **Proposed** | Draft under discussion. |
| **Accepted** | Approved; scheduled or in progress. |
| **Implemented** | Shipped. Add the version when known ("Implemented in v0.7"). |
| **In Progress** | Partly shipped. |
| **Proto** | An exploration; it records no firm decision. |
| **Closed** | Historical; the decision no longer applies. |
| **Superseded by ADR NNN** | Replaced by a newer ADR, which links back. |

## Preamble

Every ADR opens with:

```markdown
# ADR NNN — <one-line title>

- **Status**: <status from the table above> (short parenthetical qualifier OK)
- **Decider**: <who>
- **Supersedes**: <ADR NNN, or "nothing">
- **Branches from**: <ADR NNN if this builds on another decision> (optional)
- **Consequences**: <one sentence: what does this commit the project to?>
```

A short qualifier on the Status line is fine (a date, a version, a partial supersession). Longer status notes go in the body.

## Sections

Every ADR covers **Context** (the problem or constraint), **Decision** (what was decided) and **Consequences** (what follows, including trade-offs). Add **Alternatives Considered**, **Detailed Design**, **Prior Art** or **See also** where they help.

## Scope

An ADR records what was decided and why. It is not an implementation diary (commit lists belong in git history), a manual (full code and step-by-step recipes belong elsewhere), a status page (progress markers go stale), or a retrospective.

Link only to documents that will outlive the ADR: other ADRs, the user documentation, source paths. Keep an ADR as short as the decision allows. Past 300 lines, or with more code and checklists than prose, part of it belongs somewhere else.

## Drafts

Drafts live outside `docs/` while under discussion. Once accepted, the file moves to `docs/src/adrs/NNN-*.md` and gets a row in [`index.md`](index.md); the draft is deleted.
