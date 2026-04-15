!(import! &self (library lib_memo))

!(memoize sq)
(= (sq $x) (* $x $x))

; One miss, then two hits on the same key.
!(println! (sq 9))
!(println! (sq 9))
!(println! (sq 9))

!(println! (get-memoize-stats))
