---
type: reference
title: "OpenCode: running N instances in N git worktrees"
---

# OpenCode: running N instances in N git worktrees

Research date: 2026-09-25.

All source citations are from commit `adee738` (`dev`, 2026-09-25), package version
`1.18.32`. The source repo is **`anomalyco/opencode`**.

**Question:** can N OpenCode CLI instances run simultaneously, each in a different
`git worktree` of the same repo, on one machine?

**Answer:** yes, with caveats. Worktrees are a *first-class* concept in OpenCode and are
modelled as separate directories of one shared project. Nothing corrupts. The real costs
are (a) one shared SQLite database, (b) a shared project row whose `worktree` field is
first-writer-wins, and (c) unlocked read-modify-write on the global `auth.json`.

---

## 1. Where per-project state lives

All of it is global, XDG-based, and keyed off `xdg-basedir`.

`packages/core/src/global.ts:10-15`

```ts
const app = "opencode"
const data = path.join(xdgData!, app)
const cache = path.join(xdgCache!, app)
const config = path.join(xdgConfig!, app)
const state = path.join(xdgState!, app)
const tmp = path.join(os.tmpdir(), app)
```

macOS resolves to (`xdg-basedir` has no native macOS dir, so it falls back to `~/.local`):

| Path | macOS location | Contents |
| --- | --- | --- |
| `data` | `~/.local/share/opencode` | `opencode.db`, `auth.json`, `mcp-auth.json`, `log/`, `repos/`, `snapshot/`, `tool-output/` |
| `cache` | `~/.cache/opencode` | `models.json`, `bin/` |
| `config` | `~/.config/opencode` | global `opencode.json` |
| `state` | `~/.local/state/opencode` | `locks/` (cross-process file locks) |
| `tmp` | `$TMPDIR/opencode` | temp files |

Confirmed on this machine: `~/.local/share/opencode/` holds `opencode.db` (1.0 GB),
`mcp-auth.json`, `log/`, `repos/`, `snapshot/`, `tool-output/`; and
`~/.cache/opencode/models.json` (4.9 MB).

Note `global.ts:19`: `home` honours `OPENCODE_TEST_HOME`, but `data`/`cache`/`config`/`state`
do **not** — there is no env var to relocate them (see §5).

## 2. How OpenCode determines "the project" — the critical question

It walks up to find `.git`, then runs three `git rev-parse` calls.

`packages/core/src/git.ts:184-203`

```ts
const discover = Effect.fn("Git.repo.discover")(function* (input: AbsolutePath) {
  const dotgit = yield* fs.up({ targets: [".git"], start: input })...
  const cwd = path.dirname(dotgit)
  const git = run(cwd, proc)
  const topLevel  = yield* git(["rev-parse", "--show-toplevel"])
  const gitDir    = yield* git(["rev-parse", "--git-dir"])
  const commonDir = yield* git(["rev-parse", "--git-common-dir"])
  ...
  return new Repository({
    worktree: AbsolutePath.make(topLevel.exitCode === 0 ? resolvePath(cwd, topLevel.text) : cwd),
    gitDirectory: AbsolutePath.make(resolvePath(cwd, gitDir.text)),
    commonDirectory: AbsolutePath.make(resolvePath(cwd, commonDir.text)),
  })
})
```

So it captures **all three** — worktree, git dir, common dir. In a worktree:

- `worktree` → the worktree's own directory
- `gitDirectory` → `<main>/.git/worktrees/<name>` (per-worktree)
- `commonDirectory` → `<main>/.git` (**shared by all worktrees**)

### The Project ID keys on the SHARED identity

`packages/core/src/project.ts:110-122`

```ts
const resolve = Effect.fn("Project.resolve")(function* (input: AbsolutePath) {
  const repo = yield* git.repo.discover(input)
  if (!repo) return { id: ID.global, directory: AbsolutePath.make(path.parse(input).root), vcs: undefined }

  const previous = yield* cached(repo.commonDirectory)
  const id = (yield* remote(repo)) ?? previous ?? (yield* root(repo))
  return {
    previous,
    id: id ?? ID.global,
    directory: repo.worktree,
    vcs: { type: "git" as const, store: repo.commonDirectory },
  }
})
```

Priority for `id`:

1. `remote(repo)` — `Hash.fast("git-remote:" + normalizedOriginURL)` (`project.ts:73-79`)
2. `previous` — a cached id read from `<commonDirectory>/opencode`, i.e. `<main>/.git/opencode`
   (`project.ts:65-71`)
3. `root(repo)` — the repo's **root commit hash** (`project.ts:105-108`)

All three are **identical for every worktree of the same repo**. So:

> **Two worktrees of one repo resolve to the SAME `Project.ID`.**

Meanwhile `directory` is `repo.worktree` — different per worktree.

The design is explicit: a *Project* is a logical repository, and *Directories* are its
worktrees. `packages/core/src/project/sql.ts:22-35` gives `project_directory` a composite
primary key `(project_id, directory)` with a `type` of `"main" | "root" | "git_worktree"`.

## 3. What that means for collision

**Sessions and working-tree state do not collide. Some project metadata does.**

Per-worktree (no collision):

- `project_directory` rows — composite PK includes the directory
- session `directory` column; session lists filter on it
  (`packages/opencode/src/session/session.ts:557, 976, 982`)
- the snapshot shadow-git dir — `packages/core/src/snapshot.ts:98`:
  ```ts
  const gitDirectory = AbsolutePath.make(path.join(global.data, "snapshot", location.project.id, Hash.fast(worktree)))
  ```
  `project.id` is shared, `Hash.fast(worktree)` differs → distinct dirs
- config discovery — `packages/core/src/config.ts:179-184` walks up with
  `stop: location.project.directory`, so it **cannot escape the worktree root**
- in-process git locks — `packages/core/src/git.ts:181-182` keys on
  `repository.gitDirectory` (per-worktree), not the common dir

Shared (collision, though benign in practice):

- **One `project` row**, upserted by every worktree
  (`packages/opencode/src/project/project.ts:257-289`)
- **`project.worktree` is first-writer-wins.** `project.ts:237`:
  ```ts
  worktree: projectID === ProjectV2.ID.global ? worktree : existing.worktree,
  ```
  Once a row exists, later worktrees do **not** change it. Their path is appended to the
  `sandboxes` array instead (`project.ts:241-246`).
- **`<main>/.git/opencode`** is read and written by every instance on startup
  (`project.ts:65-71` read, `project.ts:124-126` write, called from
  `packages/opencode/src/project/project.ts:306-308`). Content is the same project id, so
  the write is idempotent; but it is a plain `writeFileString` with no lock, so a reader can
  momentarily observe a truncated file. The fallback (root commit) yields the same id, so
  this is cosmetic.
- **The `sandboxes` array** is a read-modify-write on a JSON column per project
  (`project.ts:241-246, 270, 284`) — two instances starting simultaneously can lose one
  worktree's entry. Recoverable: the next start of that worktree re-adds it.

## 4. Session storage

A single global SQLite database, not per project.

`packages/core/src/database/database.ts:52-54`

```ts
if (["latest", "beta", "prod"].includes(InstallationChannel) || ...) {
  return join(Global.Path.data, "opencode.db")
}
return join(Global.Path.data, `opencode-${InstallationChannel.replace(...)}.db`)
```

`packages/core/src/session/sql.ts:24-72` — one `session` table (`project_id` +
`directory`, both indexed) and one `message` table storing JSON in `data`.

So two worktrees **do write to the same file**, in the same tables, distinguished by
`project_id` + `directory`. Session IDs are timestamp+random
(`packages/core/src/id/index.ts:35-36`), so ID collisions are not a concern.

Concurrency safety comes from SQLite itself (`database.ts:28-32`):

```ts
yield* db.run("PRAGMA journal_mode = WAL")
yield* db.run("PRAGMA synchronous = NORMAL")
yield* db.run("PRAGMA busy_timeout = 5000")
yield* db.run("PRAGMA cache_size = -64000")
yield* db.run("PRAGMA foreign_keys = ON")
```

WAL + a 5 s busy timeout. Writers serialise; heavy concurrent write load can surface
`SQLITE_BUSY` past the timeout — see issue #48416 in §8.

## 5. Per-invocation overrides

Every override that exists in source. **There is no way to relocate the data directory.**

| Override | Effect | Documented? |
| --- | --- | --- |
| `OPENCODE_DB` | Path to the SQLite file. `":memory:"` or absolute path honoured; otherwise relative to `data` (`database.ts:41-45`) | **No** — absent from `cli.mdx` |
| `OPENCODE_CONFIG_DIR` | Replaces the global **config** dir only (`global.ts:64`) | Yes — `cli.mdx:686`, `config.mdx:140` |
| `OPENCODE_CONFIG` | Path to a config file | Yes — `cli.mdx` |
| `OPENCODE_CONFIG_CONTENT` | Inline config JSON | Yes — `cli.mdx` |
| `XDG_DATA_HOME` / `XDG_CACHE_HOME` / `XDG_CONFIG_HOME` / `XDG_STATE_HOME` | Relocate the *base* dirs, since `global.ts` uses `xdg-basedir` | No — inherited from the library |
| `OPENCODE_AUTH_CONTENT` | Inline auth JSON, bypassing `auth.json` (`auth/index.ts:60-63`) | No |
| `OPENCODE_MODELS_PATH` | Read models JSON from elsewhere (`models-dev.ts:184`) | No |
| `OPENCODE_DISABLE_MODELS_FETCH` | Skip the models fetch/write | Yes — `cli.mdx` |
| `OPENCODE_DISABLE_PROJECT_CONFIG` | Ignore project-level config | No |
| `OPENCODE_PURE` / `--pure` | **Plugins only** — skips external plugin discovery/install | Yes — `cli.mdx` `--pure` |
| `OPENCODE_LOG_LEVEL`, `OPENCODE_PRINT_LOGS` | Logging | Yes |

Two traps:

- **`XDG_DATA_HOME` is the only lever that moves `opencode.db`** (plus snapshots, auth,
  logs, repos). Setting it per-instance gives true isolation. It is not documented by
  OpenCode; it works because `xdg-basedir` reads it.
- **`OPENCODE_PURE` is not an isolation flag.** Despite the name, its only effects are
  `packages/opencode/src/plugin/tui/runtime.ts:1089-1090` and
  `packages/opencode/src/cli/cmd/debug/index.ts:65`. It does not touch data paths.

## 6. The `/models` provider cache

Yes, it is written to disk, atomically, and explicitly guarded for concurrent CLIs.

Location — `packages/core/src/models-dev.ts:160-164`:

```ts
const source = Flag.OPENCODE_MODELS_URL || "https://models.opencode.ai"
const filepath = path.join(
  Global.Path.cache,
  source === "https://models.opencode.ai" ? "models.json" : `models-${Hash.fast(source)}.json`,
)
```

→ `~/.cache/opencode/models.json` (confirmed present, 4.9 MB). A custom
`OPENCODE_MODELS_URL` gets its own file.

The write is temp-file + rename (`models-dev.ts:202-215`):

```ts
const tempfile = `${filepath}.${process.pid}.${Date.now()}.tmp`
yield* fs.writeWithDirs(tempfile, text).pipe(Effect.andThen(fs.rename(tempfile, filepath)), ...)
```

The temp name is **PID-scoped**, so instances never collide on it. And the fetch is under a
cross-process lock, with a comment naming the exact hazard
(`models-dev.ts:223-229`):

```ts
// Flock is cross-process: concurrent opencode CLIs can race on this cache file.
const text = yield* Effect.scoped(Effect.gen(function* () {
  yield* Flock.effect(lockKey)
  return yield* fetchAndWrite()
}))
```

`refresh()` re-checks freshness *under* the lock (`models-dev.ts:241-244`). This file is
**safe**. Note the temp files themselves are not cleaned up on a hard kill.

`Flock` (`packages/core/src/util/flock.ts`) is the real cross-process primitive: a
directory-per-lock under `<state>/locks/<hash>.lock`, acquired via `mkdir` EEXIST
(`flock.ts:148-155`), with a heartbeat for staleness (`flock.ts:225-233`) and a
token-checked release (`flock.ts:259-262`).

## 7. Everything else that could collide

| Resource | Path | Verdict |
| --- | --- | --- |
| **Sessions + messages** | `~/.local/share/opencode/opencode.db` | **Shared.** Safe via WAL + `busy_timeout=5000`; contends under load. |
| **Credentials** | `~/.local/share/opencode/auth.json` | **Shared and NOT safe.** See below. |
| **MCP auth** | `~/.local/share/opencode/mcp-auth.json` | Shared, same pattern. |
| **Server port** | — | **Safe.** `opencode serve` defaults to port `0` (`cli/network.ts:6-10`), OS-assigned. The `4096`-then-fallback path is `server.ts:120-121`. |
| **Log file** | `~/.local/share/opencode/log/opencode.log` | **Shared append.** `observability/logging.ts:49-51` uses `{ flag: "a" }`. Interleaved lines, no corruption. |
| **Run traces** | `log/direct/<stamp>-<pid>.jsonl` | Safe — PID-scoped (`cli/cmd/run/trace.ts:32`). But `latest.json` is a shared overwrite (`trace.ts:36`). |
| **Cross-process locks** | `<state>/locks/*.lock` | Safe by design (`flock.ts`). |
| **Snapshot shadow git** | `data/snapshot/<project.id>/<hash(worktree)>` | Distinct per worktree. But locking is **in-process only** — `snapshot/index.ts:55-57` uses `new Map<string, Semaphore>()`, not `Flock`. Two processes on the *same* worktree race. See #48848. |
| **Bare repo cache** | `data/repos/<host>/<path>` | Shared (keyed on remote URL, `repository.ts:126-129`) but **Flock-guarded** (`repository-cache.ts:148-149`). |
| **PID files** | none found | — |

### `auth.json` is the one genuinely unsafe shared write

`packages/opencode/src/auth/index.ts:73-81`

```ts
const set = Effect.fn("Auth.set")(function* (key: string, info: Info) {
  const norm = key.replace(/\/+$/, "")
  const data = yield* all()                    // read whole file
  if (norm !== key) delete data[key]
  delete data[norm + "/"]
  yield* fsys.writeJson(file, { ...data, [norm]: info }, 0o600)   // rewrite whole file
})
```

Read-modify-write, no lock, no temp-file+rename. Two instances refreshing an OAuth token at
the same time will clobber each other — last writer wins, whole file. That is issue #50759.
It is not a corruption risk, but a token can be lost. Since all instances read the same
tokens, the practical impact is low; it matters if two instances log into different
providers at once.

## 8. Existing issues

There is **no** issue titled around "run N worktrees in parallel". Worktree and
concurrency are both actively being worked on, and the concurrency bugs are known and open.

Concurrency (all **open**):

- [#49367 — Cross-process session concurrency: two processes can run loops on the same session simultaneously](https://github.com/anomalyco/opencode/issues/49367) (2026-09-16)
- [#48848 — Snapshot git transactions race across processes and a stale index.lock permanently wedges snapshots](https://github.com/anomalyco/opencode/issues/48848) (2026-09-13)
- [#48416 — Daily "Failed to execute statement" on macOS with concurrent opencode processes (1.18.30, busy_timeout=0, 21 GB DB)](https://github.com/anomalyco/opencode/issues/48416) (2026-09-11)
- [#50759 — V2 provider OAuth refresh races across locations and processes](https://github.com/anomalyco/opencode/issues/50759) (2026-09-22)

Worktree:

- [#51172 — Windows: worktree remove fails half-way and leaves a stale row when the worktree's location has a local MCP server running](https://github.com/anomalyco/opencode/issues/51172) (2026-09-24)
- [#51174 — protocol: field descriptions annotated after optional(...) are missing from openapi.json (e.g. worktree directory)](https://github.com/anomalyco/opencode/issues/51174) (2026-09-24)
- [#51216 — session: new session created from a project binds to the service default location and is missing from that project's history](https://github.com/anomalyco/opencode/issues/51216) (2026-09-24)
- [#51283 — sessions: V1 sessions hidden after V2 project split (global vs /home/foxkovsky)](https://github.com/anomalyco/opencode/issues/51283) — *not planned*

Two caveats on #48416: it reports `busy_timeout=0` against 1.18.30, but HEAD sets
`PRAGMA busy_timeout = 5000` at `database.ts:29`. It is unclear whether the report predates
that line or refers to a different connection. And the reporter's 21 GB DB is far larger
than typical — WAL plus a large DB is the aggravating factor. The `1.0 GB` DB on this
machine is the same shape of problem, just smaller.

## 9. Built-in file-edit isolation

Three mechanisms, none of which is automatic per-session branching.

**Snapshots — yes, on by default.** `config.ts:66-68`:

```
description: "Enable snapshots used for undo and revert behavior"
```

A shadow git repo per `(project, worktree)` (`snapshot.ts:98`) with object sharing back to
the source via `alternates` (`packages/opencode/src/snapshot/index.ts:198-226`). This is
OpenCode's own undo/revert, independent of your git history — and it means OpenCode does
**not** commit to your branch. Disable with `"snapshots": false`.

**Git worktree as a first-class copy strategy — yes.** `packages/core/src/project/copy-strategies.ts:6-35`
implements `git_worktree` with `create`/`remove`/`list` over `git worktree`. It also
**discovers externally managed worktrees** — `packages/core/test/project-copy.test.ts:299`
("refresh discovers and prunes an externally managed git worktree") and `:336` ("refresh
ignores stale git worktree registrations"). So hand-made `git worktree add` directories are
a supported input, and OpenCode will adopt them. There is **no public docs page** for this
feature; it is in the source and the protocol but not in `packages/web/src/content/docs/`.

**Sandboxes — a directory list, not an isolation mechanism.** The `sandboxes` column
(`project/sql.ts:16`) and `InstanceStore` (`packages/opencode/src/project/instance-store.ts:47-60`)
treat extra directories as *alternate roots of the same project*. A single `opencode serve`
hosts many directories, selected per request by the `x-opencode-directory` header
(`cli/cmd/serve.ts:10-11`):

> `// Server loads instances per-request via x-opencode-directory header`

Otherwise: OpenCode edits the working tree it was launched in. There is no per-session
branch, no copy-on-write, no container.

---

## Bottom line

**Running N OpenCode instances in N git worktrees of one repo is safe. Nothing corrupts,
and the design anticipates it** — worktrees are modelled as separate `project_directory`
rows of a shared project, and per-worktree state (sessions, snapshot git dirs, config
discovery, git locks) is correctly partitioned.

What is genuinely shared, in descending order of concern:

1. **`~/.local/share/opencode/auth.json`** — unlocked read-modify-write, whole-file
   overwrite (`auth/index.ts:73-81`). Concurrent OAuth refresh loses a token. Mitigate with
   `OPENCODE_AUTH_CONTENT`, or accept it.
2. **`opencode.db`** — one SQLite file for all instances. WAL + `busy_timeout=5000`
   (`database.ts:28-29`) makes this correct, not fast. Large DBs (the local one is 1.0 GB)
   raise `SQLITE_BUSY` risk — #48416.
3. **The `project` row** — `worktree` is first-writer-wins (`project.ts:237`) and the
   `sandboxes` JSON array is an unlocked read-modify-write (`project.ts:241-246`). Cosmetic
   drift in the picker; self-heals on next start.
4. **`<main>/.git/opencode`** — written unlocked by every instance (`project.ts:124-126`).
   Idempotent; a torn read falls back to the same id.
5. **`log/opencode.log`** — shared append, interleaved, harmless.

What does **not** collide: snapshot shadow repos, session/message rows, config discovery,
git locks, server ports (default `0`), PID-scoped trace files, and the models cache
(atomic rename under a cross-process `Flock`).

**Recommendation.** Run them. If you want hard isolation, set a per-instance
`XDG_DATA_HOME` — it is the only lever that moves `opencode.db`, auth, logs, snapshots and
repos together, and it works despite being undocumented. Then run `opencode auth login` once
per instance. Do not rely on `OPENCODE_PURE`; despite the name it only disables plugins.
