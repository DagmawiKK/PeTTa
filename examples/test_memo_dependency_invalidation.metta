!(import! &self (library lib_memo))

!(memoize dep-g)
!(memoize dep-f)

(= (dep-g $x) (+ $x 1))
(= (dep-f $x) (+ (dep-g $x) (dep-g $x)))

; Warm cache with old dep-g behavior: dep-f 10 => 22
!(println! (dep-f 10))

; Redefine dep-g. Dependency-aware invalidation should also invalidate dep-f.
(= (dep-g $x) (+ $x 100))
!(invalidate-memoize dep-g)

; If dependency invalidation worked, dep-f 10 => 220 (not stale 22).
!(println! (dep-f 10))
