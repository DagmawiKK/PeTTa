:- use_module(library(lists)).
:- use_module(library(solution_sequences)).

% Integration extension points
:- multifile metta_try_dispatch_call/4.
:- multifile metta_on_function_changed/1.
:- multifile metta_on_function_removed/1.

% Dynamic state
:- dynamic metta_memo_entry/5.
:- dynamic metta_memo_generation/3.
:- dynamic memo_enabled/1.
:- dynamic arity/2.
:- dynamic metta_memo_count/3.
:- dynamic metta_memo_head/3.
:- dynamic metta_memo_tail/3.
:- dynamic metta_memo_q/4.
:- dynamic memo_unique_limit/1.
:- dynamic memo_strategy/1.
:- dynamic memo_float_precision/1.
:- dynamic memo_size_limit/1.

% ============================================================================
% Core integration hooks
% ============================================================================
metta_try_dispatch_call(Fun, Args, Out, Goal) :-
    memo_enabled(Fun),
    Goal = cache_call(Fun, Args, Out).

metta_on_function_changed(Fun) :-
    cache_invalidate(Fun).

metta_on_function_removed(Fun) :-
    cache_invalidate(Fun),
    disable_memoization(Fun).

% ============================================================================
% Memo enable/disable lifecycle
% ============================================================================
enable_memoization(Fun) :-
    ( memo_enabled(Fun) -> true ; assertz(memo_enabled(Fun)) ).

disable_memoization(Fun) :-
    retractall(memo_enabled(Fun)).

% ============================================================================
% Generation + locking + invalidation
% ============================================================================
memo_current_generation(Fun, Arity, Gen) :-
    ( metta_memo_generation(Fun, Arity, Found) -> Gen = Found ; Gen = 0 ).

bump_metta_memo_generation(Fun, Arity) :-
    memo_current_generation(Fun, Arity, Prev),
    Next is Prev + 1,
    retractall(metta_memo_generation(Fun, Arity, _)),
    assertz(metta_memo_generation(Fun, Arity, Next)).

cache_fun_mutex_id(Fun, Arity, Mutex) :-
    atomic_list_concat(['metta_cache_fun_', Fun, '_', Arity], Mutex).

with_cache_fun_mutex(Fun, Arity, Goal) :-
    cache_fun_mutex_id(Fun, Arity, Mutex),
    with_mutex(Mutex, Goal).

with_cms_mutex(Goal) :-
    with_mutex(metta_cache_cms, Goal).

cache_invalidate(Fun) :-
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
              retractall(metta_memo_entry(Fun, Arity, _, _, _)),
              retractall(metta_memo_count(Fun, Arity, _)),
              retractall(metta_memo_head(Fun, Arity, _)),
              retractall(metta_memo_tail(Fun, Arity, _)),
              retractall(metta_memo_q(Fun, Arity, _, _))
            )))
    ).

cache_clear :-
    retractall(metta_memo_entry(_, _, _, _, _)),
    retractall(metta_memo_generation(_, _, _)),
    retractall(metta_memo_count(_, _, _)),
    retractall(metta_memo_head(_, _, _)),
    retractall(metta_memo_tail(_, _, _)),
    retractall(metta_memo_q(_, _, _, _)),
    ( catch(nb_current(metta_cms, _), _, fail) -> nb_delete(metta_cms) ; true ),
    ( catch(nb_current(metta_cms_size, _), _, fail) -> nb_delete(metta_cms_size) ; true ),
    ( catch(nb_current(metta_memo_accesses, _), _, fail) -> nb_delete(metta_memo_accesses) ; true ).

% ============================================================================
% Count-Min Sketch utilities (WTinyLFU frequency estimator)
% ============================================================================
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

get_freq(Fun, Arity, AVs, Freq) :-
    with_cms_mutex(
        ( catch(nb_current(metta_cms, CMS), _, fail)
        -> ( catch(nb_current(metta_cms_size, SketchSize), _, fail)
           -> true
           ; functor(CMS, _, SketchSize) ),
           term_hash((Fun, Arity, AVs), HashRaw),
           Hash is (abs(HashRaw) mod SketchSize) + 1,
           arg(Hash, CMS, Val),
           ( integer(Val) -> Freq = Val ; Freq = 0 )
        ; Freq = 0 )).

record_hit(Fun, Arity, AVs) :-
    with_cms_mutex(
        ( catch(nb_current(metta_cms, CMS), _, fail)
        -> ( catch(nb_current(metta_cms_size, SketchSize), _, fail)
           -> true
           ; functor(CMS, _, SketchSize) ),
           term_hash((Fun, Arity, AVs), HashRaw),
           Hash is (abs(HashRaw) mod SketchSize) + 1,
           arg(Hash, CMS, Val),
           ( integer(Val) -> NextVal is Val + 1 ; NextVal = 1 ),
           nb_setarg(Hash, CMS, NextVal)
        ; true )).

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
          ( NextAcc > SketchSize -> halve_cms ; true ) )).

halve_cms :-
    nb_setval(metta_memo_accesses, 0),
    nb_getval(metta_cms_size, SketchSize),
    nb_getval(metta_cms, CMS),
    forall(between(1, SketchSize, I),
        ( arg(I, CMS, Val),
          ( integer(Val) -> NewVal is Val // 2 ; NewVal = 0 ),
          nb_setarg(I, CMS, NewVal)
        )).

% ============================================================================
% Configuration defaults + config API
% ============================================================================
memo_unique_limit(100).
memo_strategy(wtinylfu).
memo_float_precision(12).
memo_size_limit(3221225472).

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
    integer(N), N > 0, !,
    retractall(memo_size_limit(_)),
    assertz(memo_size_limit(N)).
apply_memo_option([float, N]) :-
    integer(N), N >= 0, !,
    retractall(memo_float_precision(_)),
    assertz(memo_float_precision(N)).
apply_memo_option(Opt) :-
    throw(error(domain_error(memoize_option, Opt), 'config-memoize/2')).

'config-memoize'(Opt1, true) :-
    apply_memo_option(Opt1).
'config-memoize'(Opt1, Opt2, true) :-
    apply_memo_option(Opt1),
    apply_memo_option(Opt2).
'config-memoize'(Opt1, Opt2, Opt3, true) :-
    apply_memo_option(Opt1),
    apply_memo_option(Opt2),
    apply_memo_option(Opt3).

'get-memoize-config'(Config) :-
    memo_strategy(S),
    memo_unique_limit(UniqueLimit),
    memo_size_limit(SizeLimit),
    memo_float_precision(Prec),
    Config = [[strategy, S], ['unique-limit', UniqueLimit], ['size-limit', SizeLimit], [float, Prec]].

'clear-memoize!'(true) :-
    cache_clear.

'is-memoized?'(Fun, true) :-
    memo_enabled(Fun), !.
'is-memoized?'(_, false).

% ============================================================================
% Cache queue bookkeeping + eviction policy
% ============================================================================
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

memo_store(Fun, Arity, Gen, AVs, CachedResults) :-
    memo_unique_limit(Max),
    get_memo_queue_state(Fun, Arity, Count, Head, Tail),
    memo_strategy(Strategy),
    ( Count < Max
    -> Count1 is Count + 1,
       Tail1 is Tail + 1,
       assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
       assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
       set_memo_queue_state(Fun, Arity, Count1, Head, Tail1)
    ; Head1 is Head + 1,
      ( retract(metta_memo_q(Fun, Arity, Head1, VictimAVs))
      -> ( Strategy == lru
         -> retractall(metta_memo_entry(Fun, Arity, _, VictimAVs, _)),
            Tail1 is Tail + 1,
            assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
            assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
            set_memo_queue_state(Fun, Arity, Count, Head1, Tail1)
         ; get_freq(Fun, Arity, VictimAVs, VictimFreq),
           get_freq(Fun, Arity, AVs, NewFreq),
           ( NewFreq >= VictimFreq
           -> retractall(metta_memo_entry(Fun, Arity, _, VictimAVs, _)),
              Tail1 is Tail + 1,
              assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
              assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
              set_memo_queue_state(Fun, Arity, Count, Head1, Tail1)
           ; _ = Gen,
             Tail1 is Tail + 1,
             assertz(metta_memo_q(Fun, Arity, Tail1, VictimAVs)),
             set_memo_queue_state(Fun, Arity, Count, Head1, Tail1)
           )
         )
      ; Tail1 is Tail + 1,
        assertz(metta_memo_q(Fun, Arity, Tail1, AVs)),
        assertz(metta_memo_entry(Fun, Arity, Gen, AVs, CachedResults)),
        Count1 is min(Max, Count + 1),
        set_memo_queue_state(Fun, Arity, Count1, Head1, Tail1)
      )
    ).

store_if_current_generation(Fun, Arity, ExpectedGen, AVs, CachedResults) :-
    with_cache_fun_mutex(Fun, Arity,
        ( memo_current_generation(Fun, Arity, CurGen),
          ( CurGen =:= ExpectedGen
          -> memo_store(Fun, Arity, CurGen, AVs, CachedResults)
          ; true ) )).

% ============================================================================
% Key normalization + cache eligibility guards
% ============================================================================
memoizable_fun(Fun, Arity) :-
    memo_enabled(Fun),
    current_predicate(Fun/Arity),
    length(HeadArgs, Arity),
    Head =.. [Fun | HeadArgs],
    \+ predicate_property(Head, built_in).

quantize_float(V, Q) :-
    memo_float_precision(Prec),
    Scale is 10.0 ** Prec,
    Q is round(V * Scale) / Scale.

quantize_term(T, T) :-
    var(T), !.
quantize_term(T, Q) :-
    float(T), !,
    quantize_float(T, Q).
quantize_term(T, T) :-
    atomic(T), !.
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

% ============================================================================
% Memoized call execution path
% ============================================================================
memo_probe_results(Fun, AVs, ProbeResults) :-
    append(AVs, [Result], RawArgs),
    RawGoal =.. [Fun | RawArgs],
    findnsols(2, Result, call(RawGoal), ProbeResults).

cache_call(Fun, AVs, Out) :-
    append(AVs, [Out], GoalArgs),
    Goal =.. [Fun | GoalArgs],
    length(AVs, NArgs),
    Arity is NArgs + 1,
    (   ground(AVs),
        args_worth_caching(AVs),
        memoizable_fun(Fun, Arity)
    ->  quantize_term(AVs, KeyAVs),
        memo_current_generation(Fun, Arity, CurGen),
        ( metta_memo_entry(Fun, Arity, CurGen, KeyAVs, CachedResults)
        ->  record_hit(Fun, Arity, KeyAVs),
            member(Out, CachedResults)
        ;   memo_probe_results(Fun, AVs, ProbeResults),
            ( ProbeResults = [_, _|_]
            -> call(Goal)
            ; CachedResults = ProbeResults,
              store_if_current_generation(Fun, Arity, CurGen, KeyAVs, CachedResults),
              record_miss(Fun, Arity, KeyAVs),
              member(Out, CachedResults)
            )
        )
    ;   call(Goal)
    ).

% ============================================================================
% Public API: memoize a function
% ============================================================================
'memoize!'(Fun, 'Empty') :-
    ( atom(Fun), fun(Fun)
    -> true
    ; throw(error(domain_error(function_symbol, Fun), 'memoize!/2'))
    ),
    findall(Term, (translated_from(_, Term), Term = [=, [Fun|_], _]), RawTerms),
    sort(RawTerms, Terms),
    forall(member(Term, Terms), 'remove-atom'('&self', Term, _)),
    enable_memoization(Fun),
    forall(member(Term, Terms), 'add-atom'('&self', Term, _)).
