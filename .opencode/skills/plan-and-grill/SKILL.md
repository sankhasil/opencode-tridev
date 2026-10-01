# Plan and Grill

Use this skill whenever the user asks to plan a feature, refactor, or design
before writing code — or explicitly says "grill me," "review this plan," or
"walk me through the decisions before we build this."

This skill has two phases. Do not skip the interview phase, even if the
request feels obvious — the point is to surface assumptions before code
exists, not after.

## Phase 1 — Interview

Before proposing any implementation:

1. Scan the relevant part of the codebase first (`glob`, `grep`, `read`).
   Answer as many of your own questions as possible from what's actually
   there — existing patterns, naming conventions, related modules — instead
   of asking the user something the code already tells you.
2. For anything the codebase can't answer, ask the user directly. Go one
   question at a time, not a wall of questions at once. For each question,
   state your own recommended answer and ask them to confirm or override it.
3. Work through decisions in dependency order: settle things that other
   choices depend on before the choices that depend on them. Don't revisit
   a settled decision unless a later answer contradicts it.
4. Keep going until there are no more open branches — every input,
   edge case, and integration point in scope has an agreed answer.

Do not write or edit any files during this phase.

## Phase 2 — Plan and execute

Once the interview is resolved:

1. Convert the agreed decisions into a concrete, ordered task list using
   `todowrite`. Each task should be small enough to verify independently —
   prefer more small steps over fewer large ones.
2. Work through the list one task at a time. Mark each one complete only
   after it's actually done and, where applicable, verified (tests pass,
   the file compiles, the behavior was checked).
3. After finishing a task, briefly state what changed before moving to the
   next one — don't silently batch multiple tasks into one unexplained
   jump.
4. If something during execution contradicts a decision made in Phase 1,
   stop and surface it explicitly rather than quietly improvising around it.

## Notes for smaller/local models

If you are running as a smaller model, be extra disciplined about staying
inside the current phase and the current todo item. Do not jump ahead to
implementation while still in the interview phase, and do not invent a tool
or capability that isn't in your actual available tool list — if you're
unsure whether a tool exists, use `read`/`grep` to check the codebase or ask
the user rather than guessing.