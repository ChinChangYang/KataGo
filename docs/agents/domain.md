# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## The glossary is `CONTEXT.md`

This repo's glossary is **`CONTEXT.md`** at the repo root, not `GLOSSARY.md`. Wherever a skill says `GLOSSARY.md` (`/domain-modeling`, `/grill-with-docs`, `/improve-codebase-architecture`, and the rest), read and write `CONTEXT.md` instead. **Never create a `GLOSSARY.md`**: a second glossary would split the vocabulary, and `CONTEXT.md` is cited from ADRs, plans, and source comments.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo:

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-default-ruleset-tromp-taylor.md
│   └── 0008-the-board-never-waits-for-the-engine.md
├── cpp/
└── ios/KataGo iOS/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0008 (the board never waits for the engine), but worth reopening because…_
