# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues on the fork **`ChinChangYang/KataGo`**. Use the `gh` CLI for all operations.

## Repo

This clone is a fork of `lightvector/KataGo`. Pass **`-R ChinChangYang/KataGo`** to every `gh issue` / `gh label` command, and write `ChinChangYang/KataGo` in every `gh api` path. An issue must never land on upstream `lightvector/KataGo`. (`gh repo set-default ChinChangYang/KataGo` is also set in the local git config, but don't rely on it alone.)

Issues on this fork are **public**: no secrets, no credentials, and no personal email addresses (the public contact is `bolster_rotary_0x@icloud.com`).

## Conventions

- **Create an issue**: `gh issue create -R ChinChangYang/KataGo --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> -R ChinChangYang/KataGo --json number,title,body,labels,comments`.
- **List issues**: `gh issue list -R ChinChangYang/KataGo --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Make an issue a sub-issue of a parent**: `gh issue create -R ChinChangYang/KataGo --parent <parent> ...`, or `gh issue edit <parent> -R ChinChangYang/KataGo --add-sub-issue <child>` afterwards (`gh` 2.94+). Older `gh`: `gh api --method POST repos/ChinChangYang/KataGo/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>` (database id, as in **Blocking** below). Without sub-issues, put `Part of #<parent>` at the top of the child body.
- **Comment on an issue**: `gh issue comment <number> -R ChinChangYang/KataGo --body "..."`
- **Apply / remove labels**: `gh issue edit <number> -R ChinChangYang/KataGo --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> -R ChinChangYang/KataGo --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> -R ChinChangYang/KataGo --comments` and `gh pr diff <number> -R ChinChangYang/KataGo` for the diff.
- **List external PRs for triage**: `gh api --paginate 'repos/ChinChangYang/KataGo/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`.
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`, each with `-R ChinChangYang/KataGo`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42 -R ChinChangYang/KataGo` and fall back to `gh issue view 42 -R ChinChangYang/KataGo`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue on `ChinChangYang/KataGo`.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets. The `wayfinder:*` labels already exist on the repo.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create -R ChinChangYang/KataGo --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (see **Make an issue a sub-issue of a parent**). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/ChinChangYang/KataGo/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/ChinChangYang/KataGo/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list -R ChinChangYang/KataGo --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> -R ChinChangYang/KataGo --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> -R ChinChangYang/KataGo --body "<answer>"`, then `gh issue close <n> -R ChinChangYang/KataGo`, then append a context pointer (gist + link) to the map's Decisions-so-far.
