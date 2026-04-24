# lib_peano optimized behavior

This document records the production-shaping behavior layered on top of the base `lib_peano` functionality.

It covers the changes added after the initial opt-in Peano library:

- stricter Nat dispatch boundaries
- explicit mixed/canonical nat-space policy
- user-facing presentation hook
- expanded Nat numeric policy
- per-space consistency model
- hardened public API
- internal hook cleanup

## 1. Stricter Nat dispatch boundaries

Nat overloads no longer trigger just because a runtime value is a generic variable.

The runtime now uses a stricter dispatch check:

- plain numbers do not enter the Nat overload path
- non-Nat structures do not enter the Nat overload path
- strict mode requires at least one explicit Nat-shaped value:
  - `peano_int(...)`
  - `Z`
  - `S(...)`
- compat mode can still allow looser variable-driven dispatch when needed

Public config:

```metta
!(set-peano-config dispatch-mode strict)
!(set-peano-config dispatch-mode compat)
!(get-peano-config dispatch-mode)
```

Default:

```text
dispatch-mode = strict
```

Why this matters:

- fewer accidental overloads in mixed symbolic code
- less risk that generic arithmetic calls get captured by Nat logic
- better predictability in larger codebases

## 2. Mixed-mode policy

Nat-aware space operations now have an explicit mode:

- `mixed`
- `canonical`

Public config:

```metta
!(set-peano-config space-mode mixed)
!(set-peano-config space-mode canonical)
!(get-peano-config space-mode)
```

Default:

```text
space-mode = mixed
```

### `mixed`

`nat-match` and `nat-has-atom` use three layers:

1. canonical shadow index when the query clearly carries Nat intent
2. direct raw `match/4` fast path
3. fallback scan/normalize path for raw surface Nat atoms

This keeps compatibility with older mixed raw/canonical spaces.

### `canonical`

`nat-match` and `nat-has-atom` operate through the canonical Nat index only.

Effects:

- Nat-aware queries return canonical Nat values
- raw symbolic `S/Z` atoms are not treated as Nat unless they are in the index
- the Nat query path stays clean and predictable

This mode is the scalable/production-oriented one.

If a space was populated before the index existed, rebuild it:

```metta
!(nat-reindex-space &self)
```

## 3. Presentation hook

`src/ext_points.pl` now exposes:

```text
metta_present_term/2
```

`src/metta.pl` now uses that hook in:

- `repr`
- `repra`
- `println!`
- `test`

This keeps computation canonical while making user-facing rendering configurable.

Public config:

```metta
!(set-peano-config display-mode raw)
!(set-peano-config display-mode surface)
!(set-peano-config display-mode compact)
!(set-peano-config display-threshold 32)
```

Defaults:

```text
display-mode = raw
display-threshold = 32
```

Modes:

- `raw`: show canonical internal form, e.g. `peano_int(3)`
- `surface`: show `S(S(S Z))` up to the threshold, then fall back to `(fromNumber N)`
- `compact`: always show `(fromNumber N)`

Important boundary:

- presentation happens only when showing values to the user
- Nat computation still runs on canonical `peano_int(...)`
- `nat-match` does not denormalize during computation

## 4. Expanded Nat numeric policy

Nat overload coverage now includes:

- `+`
- `-`
- `*`
- `%`
- `min`
- `max`
- `<`
- `<=`
- `>`
- `>=`

New explicit Nat helpers:

- `nat-div`
- `nat-mod`
- `nat-min`
- `nat-max`
- `nat-to-number`

Additional translated helper:

- `toNumber`
- `peano.toNumber`

Policy details:

- subtraction is Nat subtraction:
  - it succeeds only when the result is still a Nat
- division/mod require a positive divisor
- comparison returns ordinary MeTTa booleans
- explicit Nat helpers accept both canonical and surface Nat inputs

Examples:

```metta
!(nat-div (S (S (S Z))) (S (S Z)))
!(nat-mod (S (S (S Z))) (S (S Z)))
!(toNumber (S (S Z)))
```

## 5. Consistency model

The runtime now uses a stable per-space mutex name derived from the space term.

Applied in:

- `src/spaces.pl` around raw space mutation
- `lib/lib_peano.pl` around Nat index reads/rebuilds

What is atomic now:

- raw atom insertion/removal
- Nat shadow-index maintenance for those mutations
- canonical index-backed Nat reads

This gives a clear consistency model:

- mutations are serialized per space
- Nat index reads do not observe half-written index state
- canonical Nat queries are consistent with the indexed view

Mixed-mode raw fast-path reads are still the lighter compatibility path; the strong consistency story is centered on the canonical indexed path.

## 6. Public API contract

Stable public Nat-space/config helpers:

- `nat-add-atom`
- `nat-remove-atom`
- `nat-match`
- `nat-has-atom`
- `nat-normalize`
- `nat-present`
- `nat-to-number`
- `nat-div`
- `nat-mod`
- `nat-min`
- `nat-max`
- `nat-reindex-space`
- `set-peano-config`
- `get-peano-config`

Configuration keys:

- `dispatch-mode`
- `space-mode`
- `display-mode`
- `display-threshold`

Accepted values:

- `dispatch-mode`: `strict`, `compat`
- `space-mode`: `mixed`, `canonical`
- `display-mode`: `raw`, `surface`, `compact`
- `display-threshold`: non-negative integer

Contract summary:

- raw `add-atom` / `remove-atom` / `match` remain raw
- Nat helpers are the Nat-aware API
- canonical Nat representation is `peano_int(N)`
- presentation is a boundary concern, not a computation concern

## 7. Internal cleanup

Two internal cleanups matter here.

### Hook fan-out

Core hook call sites now execute all matching hook clauses instead of stopping at the default no-op clause.

That affects:

- `metta_on_space_atom_added/2`
- `metta_on_space_atom_removed/2`
- `metta_on_function_changed/1`
- `metta_on_function_removed/1`

This was required for:

- the Nat shadow index
- memo invalidation
- future extension libraries

### Helper consolidation

`lib_peano` now centralizes:

- config lookup/validation
- canonical Nat normalization
- Nat presentation
- indexed Nat-space dispatch

That reduces duplicated behavior between `nat-match`, `nat-has-atom`, and the display/config helpers.

## 8. Operational guidance

Use `mixed` mode when:

- you are migrating existing code
- you want Nat-aware queries to interoperate with raw surface Nat data

Use `canonical` mode when:

- you want predictable production behavior
- you want the indexed Nat path
- you want Nat-aware queries to avoid raw symbolic leakage

Use `surface` or `compact` display modes when:

- user-facing output matters
- you want Lean-like presentation while still computing on `peano_int(...)`

Leave `raw` display mode when:

- debugging runtime representation
- comparing canonical terms directly

## 9. Current scalable path

The intended scalable production profile is:

1. import `lib_peano`
2. keep `dispatch-mode` on `strict`
3. use `space-mode` `canonical`
4. store/query Nat data through `nat-*` helpers
5. rely on canonical `peano_int(...)` for computation
6. choose `surface` or `compact` only at output time

That keeps:

- Nat execution efficient
- raw symbolic space behavior intact
- Nat-space behavior explicit
- user-facing output separate from runtime representation
