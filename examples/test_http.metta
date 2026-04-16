!(import! &self (library lib_http))

(= (and3 true true true) true)
(= (and3 $a $b $c) false)

(= (test-parallel)
  (let* (
    ($j1 (http-submit "https://httpbin.org/delay/2" "get" () ()))
    ($j2 (http-submit "https://httpbin.org/delay/2" "get" () ()))
    ($j3 (http-submit "https://httpbin.org/delay/2" "get" () ()))
    ($r1 (http-await $j1 10))
    ($r2 (http-await $j2 10))
    ($r3 (http-await $j3 10))
    ($ok1 (http-ok? $r1))
    ($ok2 (http-ok? $r2))
    ($ok3 (http-ok? $r3))
    ($all-ok (and3 $ok1 $ok2 $ok3)))
    (if $all-ok
      (println! "✅ TEST 1 PASSED: 3 parallel requests completed")
      (println! (results $ok1 $ok2 $ok3)))))

(= (test-unique-ids)
  (let* (
    ($j1 (http-submit "https://httpbin.org/get" "get" () ()))
    ($j2 (http-submit "https://httpbin.org/get" "get" () ()))
    ($j3 (http-submit "https://httpbin.org/get" "get" () ()))
    ($d12 (not (== $j1 $j2)))
    ($d23 (not (== $j2 $j3)))
    ($d13 (not (== $j1 $j3)))
    ($all-distinct (and3 $d12 $d23 $d13)))
    (if $all-distinct
      (println! "✅ TEST 2 PASSED: Jobs have unique IDs (parallel threads)")
      (println! (ids $j1 $j2 $j3)))))

(= (test-poll)
  (let* (
    ($j (http-submit "https://httpbin.org/delay/3" "get" () ()))
    ($p (http-poll $j)))
    (if (== $p pending)
      (println! "✅ TEST 3 PASSED: Polling returns immediately")
      (println! (poll-result $p)))))

(= (test-await-completed)
  (let* (
    ($j (http-submit "https://httpbin.org/get" "get" () ()))
    ($r (http-await $j 5)))
    (if (http-ok? $r)
      (println! "✅ TEST 4 PASSED: Can await and get result")
      (println! (await-failed $r)))))

(= (test-error)
  (let* (
    ($j (http-submit "https://bad-domain-xyz.com" "get" () ()))
    ($r (http-await $j 3)))
    (if (http-ok? $r)
      (println! "⚠️ TEST 5: Should have failed")
      (println! "✅ TEST 5 PASSED: Errors handled gracefully"))))

!(test-parallel)
!(test-unique-ids)
!(test-poll)
!(test-await-completed)
!(test-error)
