# Architecture Decision Records (ADRs) for petitpy

Architecture Decision Records capture the architectural decisions the project has made, together with the context that prompted each decision and its consequences. Reading them chronologically is the canonical way to understand "why is X this way?".

Inspired by [Python's PEP process](https://www.python.org/dev/peps/pep-0001/) and [Michael Nygard's original ADR sketch](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

## ADR Index

See [`index.md`](index.md) for the always-current list of ADRs with statuses and a reading order by topic.

## Statuses

| Status | Meaning |
|---|---|
| **Proposed** | Draft under discussion; not yet approved. |
| **Accepted** | Approved; scheduled or in flight. |
| **Implemented** | The decision has shipped. Add a version tag when possible ("Implemented in v0.7"). |
| **In Progress** | Some parts have shipped; the arc isn't closed. |
| **Proto** | Landscape or exploration document; it records no firm decision. |
| **Closed** | Historical; the decision it recorded has been superseded or no longer applies. |
| **Superseded by ADR NNN** | Replaced by a newer ADR. The newer one should reference back. |

## Preamble

Every ADR opens with a bulleted preamble. The fields are:

```markdown
# ADR NNN — <one-line title>

- **Status**: <status from the table above> (short parenthetical qualifier OK)
- **Decider**: <who>
- **Supersedes**: <ADR NNN, or "nothing">
- **Branches from**: <ADR NNN if this builds on another decision> (optional)
- **Consequences**: <one sentence: what does this commit the project to?>
```

Freeform prose in the Status line is fine when the qualifier adds real information (an implementation date, a partial-supersession note, a version pin). Do not stuff a status *paragraph* into the Status line; put that in the body.

## Required sections

Every ADR has three named sections. The exact headings can vary; the content must be present:

1. **Context**: what problem, constraint, or opportunity made this decision necessary?
2. **Decision**: what did we decide?
3. **Consequences**: what changes as a result (the good, the trade-offs, and the walls that follow)?

## Recommended sections

Include the ones that matter for the decision:

- **Alternatives Considered**: what else did we look at, and why did we not pick it?
- **Detailed Design**: where the shape of the solution isn't obvious from the decision alone.
- **Prior Art**: how similar systems solve the same problem.
- **See also**: pointers to other stable documents that inform or extend this decision.

## What ADRs are (and aren't)

An ADR is a **decision record**. It answers: what did we decide, why, and what follows?

An ADR is **not**:

- A play-by-play of the implementation effort. "Landed in commits X, Y, Z" or a session-by-session diary belong in git history, weekly logs, or a tech report. A single "Implemented in vX.Y.Z" line in the preamble is enough.
- An implementation manual. Full source files, complete config recipes, or step-by-step integration guides belong in a runbook or a follow-up implementation PR. The ADR captures the *shape* of the solution: enough to understand what was decided; not enough to double as documentation.
- A status page. Progress markers (✅/⏳, "P1 done, P2 pending") drift instantly and should live in an issue tracker.
- A retrospective. A retrospective on a landed decision belongs in a tech report or a weekly log, referenced from the ADR if the finding matters.

### References must be stable

An ADR should reference documents that will outlive it. That means:

- OK to link: other ADRs, user-facing `docs/`, source paths.
- Do NOT link: weekly plans, weekly logs, session-specific scratch files, an ADR's own pre-promotion draft, transient test-run captures.

If a weekly plan carried important reasoning, promote the reasoning into the ADR body; the link back to the plan will rot.

## Length and shape

Keep ADRs as short as the decision allows. Two rules of thumb:

- If the ADR is longer than 300 lines, ask what belongs elsewhere: a tech report, a lessons-learned entry, a runbook.
- If more than half the body is code blocks or checklists, the ADR has become an implementation manual. Extract the code.

## Where drafts live

Drafts sit outside `docs/` while the discussion is open. When accepted, the file moves to `docs/src/adrs/NNN-*.md` and a row appears in [`index.md`](index.md). At that point the draft file is deleted or reduced to a one-line stub pointing at the final location.

## More information

- [`index.md`](index.md): current ADR list and reading order.
- [Architectural Decision Records (Lab Abilian)](https://lab.abilian.com/Tech/Software%20Engineering/Architectural%20Decision%20Records/)
- [Python PEP Process](https://www.python.org/dev/peps/pep-0001/)
