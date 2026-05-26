/* lib_memo.pl — function-level memoization cache for MeTTa/Prolog.
 *
 * Central data structures:
 *   metta_memo_entry/5  — cached results keyed by (Fun, Arity, Gen, AVs)
 *   metta_memo_q/4      — FIFO admission queue per (Fun, Arity)
 *   metta_memo_generation/3 — invalidation generation counter
 *   metta_memo_dep/4    — caller->callee dependency graph for cascaded invalidation
 */

:- use_module(library(lists)).
:- use_module(library(solution_sequences)).

% State Declarations

% Tracks functions currently enabled for memoization.
% memo_enabled/1 means all arities for Fun are memoized.
% memo_enabled/2 means only a specific call arity (input-argument count).
:- dynamic memo_enabled/1.
:- dynamic memo_enabled/2.
:- dynamic arity/2.

% Cached results: metta_memo_entry(Fun, Arity, Gen, AVs, Results)
:- dynamic metta_memo_entry/5.

% Generation counter per (Fun, Arity) for invalidation
:- dynamic metta_memo_generation/3.

% Queue state for LRU/WTinyLFU eviction
:- dynamic metta_memo_count/3.
:- dynamic metta_memo_head/3.
:- dynamic metta_memo_tail/3.
:- dynamic metta_memo_q/4.

% Global memory tracking
:- dynamic metta_memo_total_bytes/1.

% Tracks keys currently being computed (avoids duplicate recursive probes)
:- dynamic metta_memo_in_progress/4.

% Coarse function-level dependency graph: Caller -> Callee
:- dynamic metta_memo_dep/4.

% Lightweight runtime metrics
:- dynamic metta_memo_stat/2.

% Per-thread call context to build dependency graph cheaply
:- thread_local metta_memo_call_ctx/2.

% Configuration API

:- dynamic memo_strategy/1.
:- dynamic memo_unique_limit/1.
:- dynamic memo_size_limit/1.
:- dynamic memo_float_precision/1.
:- dynamic memo_answer_limit/1.
:- dynamic memo_aggregate_mode/1.

% Defaults
memo_unique_limit(100).
memo_strategy(wtinylfu).
memo_float_precision(12).
% ~5GB global memory limit
memo_size_limit(5368709120).
% max answers stored per cache key
memo_answer_limit(2048).
% none|min|max|sum|count aggregation on ground results
memo_aggregate_mode(none).
% running total of cached bytes
metta_memo_total_bytes(0).

normalize_memo_strategy(In, wtinylfu) :-
    memberchk(In, [wtinylfu, 'WTinyLFU', 'W-TinyLFU', 'wtinylfu', 'w-tinylfu']), !.
normalize_memo_strategy(In, lru) :-
    memberchk(In, [lru, 'LRU']), !.
normalize_memo_strategy(In, Out) :-
    atom(In),
    downcase_atom(In, D),
    normalize_memo_strategy(D, Out).

apply_memo_option([strategy, Raw]) :-
    normalize_memo_strategy(Raw, S), !,
    retractall(memo_strategy(_)),
    assertz(memo_strategy(S)).
apply_memo_option(['unique-limit', N]) :-
    integer(N), N > 0, !,
    retractall(memo_unique_limit(_)),
    assertz(memo_unique_limit(N)).
apply_memo_option(['size-limit', N]) :-
    (integer(N) ; float(N)), N > 0, !,
    retractall(memo_size_limit(_)),
    Bytes is round(N * 1073741824),
    assertz(memo_size_limit(Bytes)).
apply_memo_option([float, N]) :-
    integer(N), N >= 0, !,
    retractall(memo_float_precision(_)),
    assertz(memo_float_precision(N)).
apply_memo_option(['answer-limit', N]) :-
    integer(N), N > 0, !,
    retractall(memo_answer_limit(_)),
    assertz(memo_answer_limit(N)).
apply_memo_option([aggregate, Mode]) :-
    memberchk(Mode, [none, min, max, sum, count]), !,
    retractall(memo_aggregate_mode(_)),
    assertz(memo_aggregate_mode(Mode)).
apply_memo_option(Opt) :-
    throw(error(domain_error(memoize_option, Opt), 'config-memoize/2')).

%% 'config-memoize'(+Opt, -true) is det.
%% 'config-memoize'(+Opt1, +Opt2, -true) is det.
%% 'config-memoize'(+Opt1, +Opt2, +Opt3, -true) is det.
%  Apply one to three memoization configuration options.
'config-memoize'(Opt1, true) :-
    apply_memo_option(Opt1).
'config-memoize'(Opt1, Opt2, true) :-
    apply_memo_option(Opt1),
    apply_memo_option(Opt2).
'config-memoize'(Opt1, Opt2, Opt3, true) :-
    apply_memo_option(Opt1),
    apply_memo_option(Opt2),
    apply_memo_option(Opt3).

%% 'get-memoize-config'(-Config) is det.
%  Return current configuration as a list of [Key, Value] pairs.
'get-memoize-config'(Config) :-
    memo_strategy(S),
    memo_unique_limit(UniqueLimit),
    memo_size_limit(SizeLimit),
    memo_float_precision(Prec),
    memo_answer_limit(AnswerLimit),
    memo_aggregate_mode(AggMode),
    Config = [
        [strategy, S],
        ['unique-limit', UniqueLimit],
        ['size-limit', SizeLimit],
        [float, Prec],
        ['answer-limit', AnswerLimit],
        [aggregate, AggMode]
    ].

% Stats API

memo_stat_inc(Key) :-
    ( nb_current(Key, N0) -> N is N0 + 1 ; N = 1 ),
    nb_setval(Key, N).

memo_stats_snapshot(Stats) :-
    Keys = [cache_hit, cache_miss, cache_bypass, answer_limit_truncated, waited_on_in_progress, in_progress_fallback],
    findall([K, V], (member(K, Keys), (nb_current(K, V) ; V = 0)), Stats).

%% 'get-memoize-stats'(-Stats) is det.
%  Return runtime hit/miss counters as a list of [Key, Value] pairs.
'get-memoize-stats'(Stats) :-
    memo_stats_snapshot(Stats).

%% 'clear-memoize-stats'(-true) is det.
%  Reset all runtime counters to zero.
'clear-memoize-stats'(true) :-
    retractall(metta_memo_stat(_, _)).

% Lifecycle, Dependencies, and Invalidation

enable_memoization(Fun) :-
    ( memo_enabled(Fun) -> true ; assertz(memo_enabled(Fun)) ).

enable_memoization(Fun, CallArity) :-
    ( memo_enabled(Fun, CallArity) -> true ; assertz(memo_enabled(Fun, CallArity)) ).

disable_memoization(Fun) :-
    retractall(memo_enabled(Fun)),
    retractall(memo_enabled(Fun, _)).

memo_current_generation(Fun, Arity, Gen) :-
    ( metta_memo_generation(Fun, Arity, Found) -> Gen = Found ; Gen = 0 ).

bump_metta_memo_generation(Fun, Arity) :-
    memo_current_generation(Fun, Arity, Prev),
    Next is Prev + 1,
    retractall(metta_memo_generation(Fun, Arity, _)),
    assertz(metta_memo_generation(Fun, Arity, Next)).

impacted_functions(SeedFun, Impacted) :-
    impacted_functions([SeedFun], [], Raw),
    sort(Raw, Impacted).

impacted_functions([], Seen, Seen).
impacted_functions([Fun|Rest], Seen, Impacted) :-
    ( memberchk(Fun, Seen)
    -> impacted_functions(Rest, Seen, Impacted)
    ; findall(Caller, metta_memo_dep(Caller, _, Fun, _), Callers),
      append(Rest, Callers, Next),
      impacted_functions(Next, [Fun|Seen], Impacted)
    ).

cache_invalidate_single(Fun) :-
    findall(Arity,
        ( arity(Fun, Arity)
        ; metta_memo_generation(Fun, Arity, _)
        ; metta_memo_entry(Fun, Arity, _, _, _)
        ; metta_memo_count(Fun, Arity, _)
        ; metta_memo_head(Fun, Arity, _)
        ; metta_memo_tail(Fun, Arity, _)
        ; metta_memo_q(Fun, Arity, _, _)
        ; current_predicate(Fun/Arity)
        ),
        RawArities),
    sort(RawArities, Arities),
    ( Arities == []
    -> true
    ; forall(member(Arity, Arities),
        with_cache_fun_mutex(Fun, Arity,
            ( bump_metta_memo_generation(Fun, Arity),
              invalidate_entries_for_fun_arity(Fun, Arity, FreedBytes),
              update_total_bytes(-FreedBytes),
              retractall(metta_memo_count(Fun, Arity, _)),
              retractall(metta_memo_head(Fun, Arity, _)),
              retractall(metta_memo_tail(Fun, Arity, _)),
              retractall(metta_memo_q(Fun, Arity, _, _)),
              retractall(metta_memo_in_progress(Fun, Arity, _, _))
            )))
    ),
    retractall(metta_memo_dep(Fun, _, _, _)),
    retractall(metta_memo_dep(_, _, Fun, _)).

cache_invalidate(Fun) :-
    impacted_functions(Fun, Impacted),
    forall(member(F, Impacted), cache_invalidate_single(F)).

cache_clear :-
    retractall(metta_memo_entry(_, _, _, _, _)),
    retractall(metta_memo_generation(_, _, _)),
    retractall(metta_memo_count(_, _, _)),
    retractall(metta_memo_head(_, _, _)),
    retractall(metta_memo_tail(_, _, _)),
    retractall(metta_memo_q(_, _, _, _)),
    retractall(metta_memo_in_progress(_, _, _, _)),
    retractall(metta_memo_dep(_, _, _, _)),
    retractall(metta_memo_total_bytes(_)),
    assertz(metta_memo_total_bytes(0)),
    retractall(metta_memo_stat(_, _)),
    ( catch(nb_current(metta_cms, _), _, fail) -> nb_delete(metta_cms) ; true ),
    ( catch(nb_current(metta_cms_size, _), _, fail) -> nb_delete(metta_cms_size) ; true ),
    ( catch(nb_current(metta_memo_accesses, _), _, fail) -> nb_delete(metta_memo_accesses) ; true ).

%% 'clear-memoize'(-true) is det.
%  Wipe all cached entries, counters, and dependency edges.
'clear-memoize'(true) :-
    cache_clear.

%% 'invalidate-memoize'(+Fun, -true) is det.
%  Invalidate Fun and all functions that transitively depend on it.
'invalidate-memoize'(Fun, true) :-
    cache_invalidate(Fun).

%% 'is-memoized'(+Fun, ?Bool) is det.
%% 'is-memoized'(+Fun, +CallArity, ?Bool) is det.
%  Bool is true if Fun (at CallArity) has memoization enabled, false otherwise.
'is-memoized'(Fun, true) :-
    ( memo_enabled(Fun)
    ; memo_enabled(Fun, _)
    ), !.
'is-memoized'(_, false).

'is-memoized'(Fun, CallArity, true) :-
    ( memo_enabled(Fun)
    ; memo_enabled(Fun, CallArity)
    ), !.
'is-memoized'(_, _, false).

% Runtime Hook Integration

% Hook: redirect memoization-enabled calls through cache_call/3.
:- multifile metta_try_dispatch_call/4.
metta_try_dispatch_call(Fun, Args, Out, Goal) :-
    length(Args, CallArity),
    memoization_enabled_for_call(Fun, CallArity),
    Goal = cache_call(Fun, Args, Out).

% Hook: invalidate cache when a function's definition changes.
:- multifile metta_on_function_changed/1.
metta_on_function_changed(Fun) :-
    cache_invalidate(Fun).

% Hook: invalidate cache and disable memoization when a function is removed.
:- multifile metta_on_function_removed/1.
metta_on_function_removed(Fun) :-
    cache_invalidate(Fun),
    disable_memoization(Fun).

% Key Canonicalization and Replay

memoization_enabled_for_call(Fun, CallArity) :-
    memo_enabled(Fun)
    ; memo_enabled(Fun, CallArity).

memo_enabled_arity(Fun, PredArity) :-
    integer(PredArity),
    PredArity >= 1,
    CallArity is PredArity - 1,
    memoization_enabled_for_call(Fun, CallArity).

memoizable_fun(Fun, Arity) :-
    current_predicate(Fun/Arity),
    memo_enabled_arity(Fun, Arity),
    integer(Arity),
    Arity >= 1,
    length(HeadArgs, Arity),
    Head =.. [Fun | HeadArgs],
    \+ predicate_property(Head, built_in).

quantize_float(V, Q) :-
    memo_float_precision(Prec),
    Scale is 10.0 ** Prec,
    Q is round(V * Scale) / Scale.

quantize_term(T, T) :- var(T), !.
quantize_term(T, Q) :- float(T), !, quantize_float(T, Q).
quantize_term(T, T) :- atomic(T), !.
quantize_term(T, Q) :-
    T =.. [F|Args],
    maplist(quantize_term, Args, QArgs),
    Q =.. [F|QArgs].

args_too_complex(AVs) :-
    memo_size_limit(Limit),
    term_size(AVs, S),
    EstimatedBytes is S * 8,
    EstimatedBytes > Limit.

args_worth_caching(AVs) :-
    \+ args_too_complex(AVs).

% Quantize floats then normalize variable identities to form a stable cache key.
canonicalize_args_key(AVs, KeyAVs) :-
    quantize_term(AVs, Quantized),
    copy_term(Quantized, KeyAVs),
    numbervars(KeyAVs, 0, _).

with_memo_call_context(Fun, Arity, Goal) :-
    ( metta_memo_call_ctx(ParentFun, ParentArity)
    -> ( ParentFun == Fun, ParentArity == Arity
       -> true
       ; ( metta_memo_dep(ParentFun, ParentArity, Fun, Arity)
         -> true
         ; asserta(metta_memo_dep(ParentFun, ParentArity, Fun, Arity))
         ))
    ; true ),
    setup_call_cleanup(
        asserta(metta_memo_call_ctx(Fun, Arity)),
        Goal,
        retract(metta_memo_call_ctx(Fun, Arity))).

replay_variant_answer(AVs, Out, answer(CachedAVs, CachedOut)) :-
    AVs = CachedAVs,
    Out = CachedOut.

replay_ground_answer(Out, answer(CachedOut)) :-
    Out = CachedOut.

start_in_progress(Fun, Arity, Gen, KeyAVs, Started) :-
    with_cache_fun_mutex(Fun, Arity,
        ( metta_memo_in_progress(Fun, Arity, Gen, KeyAVs)
        -> Started = false
        ; asserta(metta_memo_in_progress(Fun, Arity, Gen, KeyAVs)),
          Started = true
        )).

finish_in_progress(Fun, Arity, Gen, KeyAVs) :-
    with_cache_fun_mutex(Fun, Arity,
        retractall(metta_memo_in_progress(Fun, Arity, Gen, KeyAVs))).

wait_cached_variant(Fun, Arity, CurGen, KeyAVs, AVs, Out) :-
    wait_cached_variant(Fun, Arity, CurGen, KeyAVs, AVs, Out, 25).

wait_cached_variant(_, _, _, _, _, _, 0) :- fail.
wait_cached_variant(Fun, Arity, CurGen, KeyAVs, AVs, Out, Attempts) :-
    ( cache_lookup(Fun, Arity, CurGen, KeyAVs, CachedResults),
      member(Answer, CachedResults),
      replay_variant_answer(AVs, Out, Answer)
    -> true
    ; sleep(0.001),
      Next is Attempts - 1,
      wait_cached_variant(Fun, Arity, CurGen, KeyAVs, AVs, Out, Next)
    ).

% Probe and Aggregation

apply_aggregate_mode(ProbeResults, FinalResults) :-
    memo_aggregate_mode(Mode),
    apply_aggregate_mode(Mode, ProbeResults, FinalResults).

apply_aggregate_mode(none, ProbeResults, ProbeResults).
apply_aggregate_mode(count, ProbeResults, [answer(Count)]) :-
    length(ProbeResults, Count).
apply_aggregate_mode(Mode, ProbeResults, [answer(V)]) :-
    memberchk(Mode-Pred, [sum-sum_list, min-min_list, max-max_list]),
    findall(X, member(answer(X), ProbeResults), Values),
    call(Pred, Values, V).

truncate_answers(Answers, Limited) :-
    memo_answer_limit(Limit),
    length(Prefix, Limit),
    append(Prefix, _, Answers), !,
    Limited = Prefix.
truncate_answers(Answers, Answers).

% Runtime Dispatch

% Collect all variant answers for a non-ground call.
memo_probe_results(Fun, AVs, ProbeResults) :-
    memo_answer_limit(Limit),
    append(AVs, [Result], RawArgs),
    RawGoal =.. [Fun | RawArgs],
    findnsols(Limit, answer(SolvedAVs, SolvedResult),
        ( call(RawGoal),
          copy_term((AVs, Result), (SolvedAVs, SolvedResult))
        ),
        ProbeResults).

% Collect ground-path answers; skip re-unifying inputs on replay because
% float quantization maps slightly different inputs to the same key.
memo_probe_ground_results(Fun, AVs, ProbeResults) :-
    memo_answer_limit(Limit),
    append(AVs, [Result], RawArgs),
    RawGoal =.. [Fun | RawArgs],
    findnsols(Limit, answer(SolvedResult),
        ( call(RawGoal),
          copy_term(Result, SolvedResult)
        ),
        ProbeResults).

cache_lookup(Fun, Arity, CurGen, KeyAVs, CachedResults) :-
    metta_memo_entry(Fun, Arity, CurGen, KeyAVs, CachedResults).

cache_replay_hit_ground(Fun, Arity, KeyAVs, CachedResults, Out) :-
    memo_stat_inc(cache_hit),
    record_hit(Fun, Arity, KeyAVs),
    member(Answer, CachedResults),
    replay_ground_answer(Out, Answer).

cache_replay_hit_variant(Fun, Arity, KeyAVs, CachedResults, AVs, Out) :-
    memo_stat_inc(cache_hit),
    record_hit(Fun, Arity, KeyAVs),
    member(Answer, CachedResults),
    replay_variant_answer(AVs, Out, Answer).

cache_store(Fun, Arity, CurGen, KeyAVs, ProbeResults) :-
    truncate_answers(ProbeResults, LimitedResults),
    ( LimitedResults == ProbeResults -> true ; memo_stat_inc(answer_limit_truncated) ),
    store_if_gen(Fun, Arity, CurGen, KeyAVs, LimitedResults),
    record_miss(Fun, Arity, KeyAVs).

probe_store_variant(Fun, Arity, CurGen, KeyAVs, AVs, ProbeResults) :-
    setup_call_cleanup(
        true,
        memo_probe_results(Fun, AVs, ProbeResults),
        finish_in_progress(Fun, Arity, CurGen, KeyAVs)),
    cache_store(Fun, Arity, CurGen, KeyAVs, ProbeResults).

cache_probe_and_store_ground(Fun, Arity, CurGen, KeyAVs, AVs, ProbeResults) :-
    setup_call_cleanup(
        true,
        memo_probe_ground_results(Fun, AVs, ProbeResults),
        finish_in_progress(Fun, Arity, CurGen, KeyAVs)),
    apply_aggregate_mode(ProbeResults, AggregatedResults),
    cache_store(Fun, Arity, CurGen, KeyAVs, AggregatedResults).

cache_call_cached_ground(Fun, Arity, CurGen, KeyAVs, Out) :-
    cache_lookup(Fun, Arity, CurGen, KeyAVs, CachedResults),
    !,
    member(Answer, CachedResults),
    replay_ground_answer(Out, Answer).

cache_call_store_ground(Fun, Arity, CurGen, KeyAVs, AVs, _Goal, Out) :-
    % Collisions on quantized keys are intentional; skip in-progress guard to
    % avoid duplicate recomputation in recursive workloads.
    memo_probe_ground_results(Fun, AVs, ProbeResults),
    apply_aggregate_mode(ProbeResults, FinalResults),
    cache_store(Fun, Arity, CurGen, KeyAVs, FinalResults),
    memo_stat_inc(cache_miss),
    member(Answer, FinalResults),
    replay_ground_answer(Out, Answer).

cache_call_store_variant(Fun, Arity, CurGen, KeyAVs, AVs, Goal, Out) :-
    start_in_progress(Fun, Arity, CurGen, KeyAVs, Started),
    ( Started == true
    -> probe_store_variant(Fun, Arity, CurGen, KeyAVs, AVs, ProbeResults),
       memo_stat_inc(cache_miss),
       member(Answer, ProbeResults),
       replay_variant_answer(AVs, Out, Answer)
    ; ( wait_cached_variant(Fun, Arity, CurGen, KeyAVs, AVs, Out)
      -> memo_stat_inc(waited_on_in_progress)
      ; memo_stat_inc(in_progress_fallback),
        call(Goal)
      )
    ).

cache_call(Fun, AVs, Out) :-
    append(AVs, [Out], GoalArgs),
    Goal =.. [Fun | GoalArgs],
    length(AVs, NArgs),
    Arity is NArgs + 1,
    with_memo_call_context(Fun, Arity,
    ( args_worth_caching(AVs),
      memoizable_fun(Fun, Arity)
    -> canonicalize_args_key(AVs, KeyAVs),
        memo_current_generation(Fun, Arity, CurGen),
        ( ground(AVs)
        -> ( cache_lookup(Fun, Arity, CurGen, KeyAVs, CachedResults)
           -> cache_replay_hit_ground(Fun, Arity, KeyAVs, CachedResults, Out)
           ; cache_call_store_ground(Fun, Arity, CurGen, KeyAVs, AVs, Goal, Out)
           )
        ; ( cache_lookup(Fun, Arity, CurGen, KeyAVs, CachedResults)
          -> cache_replay_hit_variant(Fun, Arity, KeyAVs, CachedResults, AVs, Out)
          ; cache_call_store_variant(Fun, Arity, CurGen, KeyAVs, AVs, Goal, Out)
          )
        )
    ; memo_stat_inc(cache_bypass),
      call(Goal)
    )).

% Synchronization Helpers

cache_fun_mutex_id(Fun, Arity, Mutex) :-
    atomic_list_concat(['metta_cache_fun_', Fun, '_', Arity], Mutex).

with_cache_fun_mutex(Fun, Arity, Goal) :-
    cache_fun_mutex_id(Fun, Arity, Mutex),
    with_mutex(Mutex, Goal).

with_cms_mutex(Goal) :-
    with_mutex(metta_cache_cms, Goal).

% Frequency Sketch (WTinyLFU)

ensure_cms :-
    ( catch(nb_current(metta_cms, _), _, fail),
      catch(nb_current(metta_cms_size, _), _, fail)
    -> true
    ; current_prolog_flag(max_arity, MaxArity0),
      ( integer(MaxArity0), MaxArity0 > 0 -> MaxArity = MaxArity0 ; MaxArity = 1024 ),
      SketchSize is min(8192, MaxArity),
      functor(CMS, v, SketchSize),
      forall(between(1, SketchSize, I), nb_setarg(I, CMS, 0)),
      nb_setval(metta_cms, CMS),
      nb_setval(metta_cms_size, SketchSize),
      nb_setval(metta_memo_accesses, 0)
    ).

cms_slot(Fun, Arity, AVs, CMS, Hash) :-
    catch(nb_current(metta_cms, CMS), _, fail),
    ( catch(nb_current(metta_cms_size, SketchSize), _, fail)
    -> true
    ; functor(CMS, _, SketchSize) ),
    term_hash((Fun, Arity, AVs), HashRaw),
    Hash is (abs(HashRaw) mod SketchSize) + 1.

get_freq(Fun, Arity, AVs, Freq) :-
    with_cms_mutex(
        ( cms_slot(Fun, Arity, AVs, CMS, Hash)
        -> arg(Hash, CMS, Val),
           ( integer(Val) -> Freq = Val ; Freq = 0 )
        ; Freq = 0 )
    ).

record_hit(Fun, Arity, AVs) :-
    with_cms_mutex(
        ( cms_slot(Fun, Arity, AVs, CMS, Hash)
        -> arg(Hash, CMS, Val),
           ( integer(Val) -> NextVal is Val + 1 ; NextVal = 1 ),
           nb_setarg(Hash, CMS, NextVal)
        ; true )
    ).

record_miss(Fun, Arity, AVs) :-
    with_cms_mutex(
        ( ensure_cms,
          nb_getval(metta_cms_size, SketchSize),
          term_hash((Fun, Arity, AVs), HashRaw),
          Hash is (abs(HashRaw) mod SketchSize) + 1,
          nb_getval(metta_cms, CMS),
          arg(Hash, CMS, Val),
          ( integer(Val) -> NextVal is Val + 1 ; NextVal = 1 ),
          nb_setarg(Hash, CMS, NextVal),
          nb_getval(metta_memo_accesses, Acc),
          NextAcc is Acc + 1,
          nb_setval(metta_memo_accesses, NextAcc),
          ( NextAcc > SketchSize -> halve_cms ; true )
        )
    ).

halve_cms :-
    nb_setval(metta_memo_accesses, 0),
    nb_getval(metta_cms_size, SketchSize),
    nb_getval(metta_cms, CMS),
    forall(between(1, SketchSize, I),
        ( arg(I, CMS, Val),
          ( integer(Val) -> NewVal is Val // 2 ; NewVal = 0 ),
          nb_setarg(I, CMS, NewVal)
        )).

% Storage and Eviction

% Read queue counters; default to 0 when not yet initialised.
get_memo_queue_state(Fun, Arity, Count, Head, Tail) :-
    ( metta_memo_count(Fun, Arity, C) -> Count = C ; Count = 0 ),
    ( metta_memo_head(Fun, Arity, H) -> Head = H ; Head = 0 ),
    ( metta_memo_tail(Fun, Arity, T) -> Tail = T ; Tail = 0 ).

set_memo_queue_state(Fun, Arity, Count, Head, Tail) :-
    retractall(metta_memo_count(Fun, Arity, _)),
    retractall(metta_memo_head(Fun, Arity, _)),
    retractall(metta_memo_tail(Fun, Arity, _)),
    asserta(metta_memo_count(Fun, Arity, Count)),
    asserta(metta_memo_head(Fun, Arity, Head)),
    asserta(metta_memo_tail(Fun, Arity, Tail)).

% Storage - Eviction Policies (LRU and WTinyLFU)

% Estimated byte cost of one cache entry (term_size * 8 bytes/word).
entry_size(AVs, Results, Bytes) :-
    term_size(AVs, S1),
    term_size(Results, S2),
    Bytes is (S1 + S2) * 8.

% Find the globally oldest queue entry by minimum head value.
find_global_oldest(Fun, Arity, AVs) :-
    findall((HeadVal, F, A),
        metta_memo_head(F, A, HeadVal),
        Heads),
    Heads = [_|_],
    % Sort by (HeadVal, Fun, Arity); ties in HeadVal are broken by Fun (alphabetically) then Arity.
    sort(Heads, Sorted),
    Sorted = [(MinHead, Fun, Arity)|_],
    Next is MinHead + 1,
    metta_memo_q(Fun, Arity, Next, AVs).

% Safety cap on recursive eviction loops.
max_eviction_attempts(1000).

% Evict globally until NeededBytes fits within the size limit.
evict_global_space(NeededBytes) :-
    evict_global_space(NeededBytes, 0).

evict_global_space(NeededBytes, Attempts) :-
    max_eviction_attempts(MaxAttempts),
    ( Attempts >= MaxAttempts
    -> format(user_error, 'WARNING: Memoization eviction limit exceeded (~d attempts).~n', [MaxAttempts]),
       true  % Stop trying, but don't fail
    ; memo_size_limit(Limit),
      metta_memo_total_bytes(Current),
      NewTotal is Current + NeededBytes,
      ( NewTotal =< Limit
      -> true  % Space available now
      ; % Need to evict
        ( find_global_oldest(Fun, Arity, VictimAVs)
        -> evict_entry(Fun, Arity, VictimAVs),
           NewAttempts is Attempts + 1,
           evict_global_space(NeededBytes, NewAttempts)
        ; true
        )
      )
    ).

% Remove one entry from the cache and adjust the global byte counter.
evict_entry(Fun, Arity, AVs) :-
    ( metta_memo_entry(Fun, Arity, _, AVs, CachedResults)
    -> entry_size(AVs, CachedResults, Bytes),
       retractall(metta_memo_entry(Fun, Arity, _, AVs, _)),
       ( metta_memo_q(Fun, Arity, _, AVs)
       -> ( metta_memo_head(Fun, Arity, Head)
          -> Head1 is Head + 1,
             retractall(metta_memo_head(Fun, Arity, _)),
             asserta(metta_memo_head(Fun, Arity, Head1))
          ; true
          ),
          retractall(metta_memo_q(Fun, Arity, _, AVs)),
          ( metta_memo_count(Fun, Arity, Count)
          -> Count1 is Count - 1,
             retractall(metta_memo_count(Fun, Arity, _)),
             asserta(metta_memo_count(Fun, Arity, Count1))
          ; true
          )
       ; true
       ),
       ( metta_memo_total_bytes(Total)
       -> NewTotal is max(0, Total - Bytes),
          retractall(metta_memo_total_bytes(_)),
          assertz(metta_memo_total_bytes(NewTotal))
       ; assertz(metta_memo_total_bytes(0))
       )
    ; true
    ).

% Retract all entries for (Fun, Arity) and return the total bytes freed.
invalidate_entries_for_fun_arity(Fun, Arity, FreedBytes) :-
    findall(Bytes,
        ( metta_memo_entry(Fun, Arity, _, AVs, CachedResults),
          entry_size(AVs, CachedResults, Bytes)
        ),
        Sizes),
    sum_list(Sizes, FreedBytes),
    retractall(metta_memo_entry(Fun, Arity, _, _, _)).

update_total_bytes(Delta) :-
    ( retract(metta_memo_total_bytes(Current))
    -> true
    ; Current = 0
    ),
    New is max(0, Current + Delta),
    assertz(metta_memo_total_bytes(New)).

% Store a result, enforcing the unique-entry limit and eviction policy.
insert_cache_entry(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count1, Head, Tail) :-
    Tail1 is Tail + 1,
    assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
    assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
    update_total_bytes(NewBytes),
    set_memo_queue_state(Fun, Arity, Count1, Head, Tail1).

memo_store(Fun, Arity, Gen, AVs, CachedResults) :-
    memo_unique_limit(Max),
    get_memo_queue_state(Fun, Arity, Count, Head, Tail),
    entry_size(AVs, CachedResults, NewBytes),
    evict_global_space(NewBytes),
    memo_strategy(Strategy),
    ( Count < Max
    -> Count1 is Count + 1,
       insert_cache_entry(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count1, Head, Tail)
    ; Head1 is Head + 1,
      ( retract(metta_memo_q(Fun, Arity, Head1, VictimAVs))
      -> ( Strategy == lru
         -> memo_store_lru(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs)
         ; memo_store_wtinylfu(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs)
         )
      ; Count1 is min(Max, Count + 1),
        insert_cache_entry(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count1, Head1, Tail)
      )
    ).

evict_victim_and_admit(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs) :-
    ( metta_memo_entry(Fun, Arity, _, VictimAVs, VictimResults)
    -> entry_size(VictimAVs, VictimResults, VictimBytes),
       retractall(metta_memo_entry(Fun, Arity, _, VictimAVs, _)),
       ( retract(metta_memo_total_bytes(CurrentTotal))
       -> NewTotal is CurrentTotal - VictimBytes + NewBytes
       ; NewTotal is NewBytes
       ),
       assertz(metta_memo_total_bytes(NewTotal))
    ; true
    ),
    Tail1 is Tail + 1,
    assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
    assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
    set_memo_queue_state(Fun, Arity, Count, Head1, Tail1).

% LRU path: evict victim unconditionally and admit the new entry.
memo_store_lru(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs) :-
    evict_victim_and_admit(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs).

% WTinyLFU path: admit new entry only if its frequency >= victim's frequency.
memo_store_wtinylfu(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs) :-
    get_freq(Fun, Arity, VictimAVs, VictimFreq),
    get_freq(Fun, Arity, AVs, NewFreq),
    ( NewFreq >= VictimFreq
    -> evict_victim_and_admit(Fun, Arity, Gen, AVs, CachedResults, NewBytes, Count, Head1, Tail, VictimAVs)
    ; Tail1 is Tail + 1,
      assertz(metta_memo_q(Fun, Arity, Tail1, VictimAVs)),
      set_memo_queue_state(Fun, Arity, Count, Head1, Tail1)
    ).

store_if_gen(Fun, Arity, ExpectedGen, AVs, CachedResults) :-
    with_cache_fun_mutex(Fun, Arity,
        ( memo_current_generation(Fun, Arity, CurGen),
          ( CurGen =:= ExpectedGen
          -> memo_store(Fun, Arity, CurGen, AVs, CachedResults)
          ; true )
        )).

% Public API

memoize_reload(Terms) :-
    forall(member(Term, Terms), 'remove-atom'('&self', Term, _)),
    forall(member(Term, Terms), 'add-atom'('&self', Term, _)).

%% 'memoize'(+Fun, -'Empty') is det.
%  Enable memoization for all arities of Fun and reload its clauses.
'memoize'(Fun, 'Empty') :-
    ( atom(Fun), fun(Fun)
    -> true
    ; throw(error(domain_error(function_symbol, Fun), 'memoize!/2'))
    ),
    findall(Term,
        (translated_from(_, Term), Term = [=, [Fun|_], _]),
        RawTerms),
    sort(RawTerms, Terms),
    enable_memoization(Fun),
    memoize_reload(Terms).

%% 'memoize'(+Fun, +CallArity, -'Empty') is det.
%  Enable memoization for Fun at a specific call arity and reload its clauses.
'memoize'(Fun, CallArity, 'Empty') :-
    ( atom(Fun), fun(Fun)
    -> true
    ; throw(error(domain_error(function_symbol, Fun), 'memoize!/3'))
    ),
    ( integer(CallArity), CallArity >= 0
    -> true
    ; throw(error(domain_error(nonneg_integer, CallArity), 'memoize!/3'))
    ),
    findall(Term,
        ( translated_from(_, Term),
          Term = [=, [Fun|Args], _],
          length(Args, CallArity)
        ),
        RawTerms),
    sort(RawTerms, Terms),
    enable_memoization(Fun, CallArity),
    memoize_reload(Terms).
