# lib_peano

`lib_peano` is an opt-in MeTTa library that gives Peano naturals an efficient internal representation while keeping default atomspace behavior unchanged.

Load it with:

```metta
!(import! &self (library lib_peano))
```

After import, the library adds Peano-aware translation, Nat-aware arithmetic dispatch, and Nat-aware space helpers.

## What It Adds

The library uses a canonical internal Nat form:

- `Z` -> `peano_int(0)`
- `(S Z)` -> `peano_int(1)`
- `(S (S Z))` -> `peano_int(2)`

That canonical form is used during Nat-aware computation. Surface `Z` / `S(...)` syntax is still written in MeTTa source.

Public helpers imported by `lib/lib_peano.metta`:

- `nat-add-atom`
- `nat-remove-atom`
- `nat-match`
- `nat-has-atom`

## Core Behavior

### Translation

`lib_peano` installs translation/runtime hooks so that:

- `Z` lowers to `peano_int(0)`
- `S(X)` lowers to a successor relation over `peano_int(...)`
- `fromNumber(N)` lowers directly to `peano_int(N)`
- `peano.fromNumber(N)` lowers directly to `peano_int(N)`
- typed `Nat` arguments can lower numbers into `peano_int(...)`

This lets recursive Nat code compute over canonical integer-backed values instead of nested unary terms.

### Arithmetic And Comparison

The library overloads Nat-aware arithmetic/comparison through runtime dispatch.

Supported overloaded operators:

- `+`
- `-`
- `*`
- `<`
- `<=`
- `>`
- `>=`

These overloads operate on canonical `peano_int(N)` values and preserve Nat constraints.

### Raw Space Ops Stay Raw

Core atomspace operations remain literal:

- `add-atom`
- `remove-atom`
- `match`

So symbolic data like this stays symbolic:

```metta
!(add-atom &self (my_data (S T)))
!(match &self (my_data $x) $x)
```

The result is still `(S T)`.

### Nat-Aware Space Ops

When Nat semantics are intended, use:

- `nat-add-atom`
- `nat-remove-atom`
- `nat-match`
- `nat-has-atom`

These helpers normalize surface Peano syntax when needed and let Nat-heavy code work against canonical `peano_int(...)` values.

Examples:

```metta
!(nat-add-atom &self (num Z))
!(nat-add-atom &self (num (S Z)))
!(nat-match &self (num $n) $n)
```

## How `nat-match` Works

`nat-match` prepares the query once and then uses two paths:

1. A fast path that tries direct raw `match/4` on the normalized pattern/body.
2. A fallback path that scans stored atoms, normalizes raw surface Peano atoms, and matches against the canonical query.

This keeps canonical Nat queries efficient while still allowing interoperability with raw stored surface Peano atoms.

`nat-has-atom` follows the same pattern, but returns only a boolean existence result.

## Raw And Nat Paths

The intended split is:

- use raw space ops for symbolic data
- use Nat-aware space ops for Nat data
- use overloaded arithmetic on canonical Nat values or Nat-aware translated code

This avoids the ambiguity in an untyped or partially typed atomspace where `(S T)` may be either symbolic data or an intended Nat constructor.

## Internal Representation

The canonical runtime representation is `peano_int(N)`.

That representation is what the Nat-aware parts of the runtime use for:

- arithmetic
- comparison
- recursive Nat programs
- Nat-aware space operations

The surface syntax remains available in source code, but the Nat-aware execution path works on the canonical form.

## Performance Model

The main speed win comes from using `peano_int(N)` internally instead of recursive unary structure during Nat-aware computation.

This makes:

- Nat arithmetic faster
- recursive Nat evaluation faster
- inverse Nat programs practical through the relational `S` path

It does not automatically make every Nat-shaped program fast. Programs dominated by repeated whole-space scans can still be slow because their main cost is atomspace traversal rather than successor arithmetic.

## Memoization

Pure Nat computations can work well with memoization.

Space-driven Nat programs need more care: if a function depends on mutable atomspace contents, memoization safety depends on how cache invalidation interacts with space mutation.

## Recommended Usage

Use `lib_peano` when you want:

- Peano syntax in source
- efficient Nat execution
- inverse Nat computation
- Nat-aware atomspace helpers without changing raw atomspace semantics

Use raw space ops when you want literal symbolic data.

Use the Nat-aware helpers when you want Nat semantics.
