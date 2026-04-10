:- use_module(library(lists)).

:- dynamic metta_memo_entry/6.
:- dynamic metta_memo_generation/3.
:- dynamic memo_enabled/1.
:- dynamic memo_disabled_runtime/1.

enable_memoization(Fun) :-
    ( memo_enabled(Fun) -> true ; assertz(memo_enabled(Fun)) ).

disable_memoization(Fun) :-
    retractall(memo_enabled(Fun)),
    retractall(memo_disabled_runtime(Fun)).

runtime_disable(Fun) :-
    ( memo_disabled_runtime(Fun) -> true
    ; assertz(memo_disabled_runtime(Fun))
    ).

ensure_metta_memo_counters :-
    ( catch(nb_current(metta_memo_seq, _), _, fail) -> true ; nb_setval(metta_memo_seq, 0) ),
    ( catch(nb_current(metta_memo_size, _), _, fail) -> true ; nb_setval(metta_memo_size, 0) ),
    ( catch(nb_current(metta_memo_oldest, _), _, fail) -> true ; nb_setval(metta_memo_oldest, 1) ).

memo_next_seq(Seq) :-
    ensure_metta_memo_counters,
    nb_getval(metta_memo_seq, Prev),
    Seq is Prev + 1,
    nb_setval(metta_memo_seq, Seq).

memo_size_inc :-
    ensure_metta_memo_counters,
    nb_getval(metta_memo_size, Prev),
    Next is Prev + 1,
    nb_setval(metta_memo_size, Next).

memo_size_dec :-
    ensure_metta_memo_counters,
    nb_getval(metta_memo_size, Prev),
    Next is max(0, Prev - 1),
    nb_setval(metta_memo_size, Next).

memo_current_generation(Fun, Arity, Gen) :-
    ( metta_memo_generation(Fun, Arity, Found) -> Gen = Found ; Gen = 0 ).

bump_metta_memo_generation(Fun, Arity) :-
    memo_current_generation(Fun, Arity, Prev),
    Next is Prev + 1,
    retractall(metta_memo_generation(Fun, Arity, _)),
    assertz(metta_memo_generation(Fun, Arity, Next)).

cache_invalidate(Fun) :-
    findall(Arity, arity(Fun, Arity), RawArities),
    sort(RawArities, Arities),
    ( Arities == [] -> true
    ; forall(member(Arity, Arities),
        ( bump_metta_memo_generation(Fun, Arity)
        ))
    ).

cache_clear :-
    retractall(metta_memo_entry(_, _, _, _, _, _)),
    retractall(metta_memo_generation(_, _, _)),
    retractall(memo_disabled_runtime(_)),
    nb_setval(metta_memo_seq, 0),
    nb_setval(metta_memo_size, 0),
    nb_setval(metta_memo_oldest, 1),
    ( catch(nb_current(metta_cms, _), _, fail) -> nb_delete(metta_cms) ; true ).

metta_memo_limit(10000).

ensure_cms :-
    ( catch(nb_current(metta_cms, _), _, fail) -> true
    ; functor(CMS, v, 8192),
      forall(between(1, 8192, I), nb_setarg(I, CMS, 0)),
      nb_setval(metta_cms, CMS)
    ),
    ( catch(nb_current(metta_memo_accesses, _), _, fail) -> true
    ; nb_setval(metta_memo_accesses, 0)
    ).

record_access(Fun, AVs) :-
    ensure_cms,
    Key = Fun-AVs,
    term_hash(Key, HashRaw),
    Hash is (abs(HashRaw) mod 8192) + 1,
    nb_getval(metta_cms, CMS),
    arg(Hash, CMS, Val),
    ( integer(Val) -> NextVal is Val + 1 ; NextVal = 1 ),
    nb_setarg(Hash, CMS, NextVal),
    
    nb_getval(metta_memo_accesses, Acc),
    ( integer(Acc) -> NextAcc is Acc + 1 ; NextAcc = 1 ),
    nb_setval(metta_memo_accesses, NextAcc),
    ( NextAcc > 10000 -> halve_cms ; true ).

get_freq(Fun, AVs, Freq) :-
    ensure_cms,
    Key = Fun-AVs,
    term_hash(Key, HashRaw),
    Hash is (abs(HashRaw) mod 8192) + 1,
    nb_getval(metta_cms, CMS),
    arg(Hash, CMS, Val),
    ( integer(Val) -> Freq = Val ; Freq = 0 ).

halve_cms :-
    nb_setval(metta_memo_accesses, 0),
    nb_getval(metta_cms, CMS),
    functor(CMS, _, Arity),
    forall(between(1, Arity, I),
        ( arg(I, CMS, Val),
          ( integer(Val) -> NewVal is Val // 2 ; NewVal = 0 ),
          nb_setarg(I, CMS, NewVal)
        )).


find_victim(VFun, VArity, VGen, VAVs, VSeq, VCached) :-
    ensure_metta_memo_counters,
    nb_getval(metta_memo_oldest, Oldest),
    nb_getval(metta_memo_seq, MaxSeq),
    find_victim_scan(Oldest, MaxSeq, VFun, VArity, VGen, VAVs, VSeq, VCached, NextOldest),
    nb_setval(metta_memo_oldest, NextOldest).

find_victim_scan(Old, Max, VFun, VArity, VGen, VAVs, VSeq, VCached, NextOldest) :-
    Old =< Max,
    ( metta_memo_entry(VFun, VArity, VGen, VAVs, Old, VCached) ->
        VSeq = Old,
        NextOldest is Old + 1
    ;   Old1 is Old + 1,
        find_victim_scan(Old1, Max, VFun, VArity, VGen, VAVs, VSeq, VCached, NextOldest)
    ).

memo_store(Fun, Arity, Gen, AVs, CachedResults) :-
    metta_memo_limit(Limit),
    ensure_metta_memo_counters,
    nb_getval(metta_memo_size, Size),
    ( Size < Limit ->
        % Direct admission if under limit
        memo_next_seq(Seq),
        assertz(metta_memo_entry(Fun, Arity, Gen, AVs, Seq, CachedResults)),
        memo_size_inc
    ;
        % Cache is full. TinyLFU admission comparison.
        get_freq(Fun, AVs, NewFreq),
        ( find_victim(VFun, VArity, VGen, VAVs, VSeq, VCached) ->
            get_freq(VFun, VAVs, VictimFreq),
            ( NewFreq >= VictimFreq ->
                % Admit new, evict victim
                retract(metta_memo_entry(VFun, VArity, VGen, VAVs, VSeq, VCached)),
                memo_next_seq(Seq),
                assertz(metta_memo_entry(Fun, Arity, Gen, AVs, Seq, CachedResults))
            ;
                retract(metta_memo_entry(VFun, VArity, VGen, VAVs, VSeq, VCached)),
                memo_next_seq(UpdatedVSeq),
                assertz(metta_memo_entry(VFun, VArity, VGen, VAVs, UpdatedVSeq, VCached))
            )
        ;   % Failsafe if scan failed: just insert
            memo_next_seq(Seq),
            assertz(metta_memo_entry(Fun, Arity, Gen, AVs, Seq, CachedResults)),
            memo_size_inc
        )
    ).

memoizable_fun(Fun, Arity) :-
    memo_enabled(Fun),
    \+ memo_disabled_runtime(Fun),          % permanently ruled out at runtime
    arity(Fun, Arity),
    current_predicate(Fun/Arity),
    length(HeadArgs, Arity),
    Head =.. [Fun | HeadArgs],
    \+ predicate_property(Head, built_in).

memo_arg_size_limit(200).

args_contain_float(AVs) :-
    sub_term(X, AVs),
    float(X), !.

args_too_complex(AVs) :-
    memo_arg_size_limit(Limit),
    term_size(AVs, S),
    S > Limit.

args_worth_caching(AVs) :-
    \+ args_contain_float(AVs),
    \+ args_too_complex(AVs).

:- dynamic cache_unique_threshold/1.
cache_unique_threshold(100).

should_cache(Fun, Arity, AVs) :-
    metta_memo_entry(Fun, Arity, _, AVs, _, _), !.

should_cache(Fun, Arity, _AVs) :-
    aggregate_all(count, metta_memo_entry(Fun, Arity, _, _, _, _), Count),
    cache_unique_threshold(Max),
    Count < Max.

cache_call(Fun, AVs, Out) :-
    append(AVs, [Out], GoalArgs),
    Goal =.. [Fun | GoalArgs],
    length(AVs, NArgs),
    Arity is NArgs + 1,
    (   \+ memo_disabled_runtime(Fun),
        ground(AVs),
        args_worth_caching(AVs),            % rejects floats and oversized terms
        memoizable_fun(Fun, Arity),
        should_cache(Fun, Arity, AVs)       % threshold checked BEFORE findall
    ->  memo_current_generation(Fun, Arity, Gen),
        record_access(Fun, AVs),            % $O(1)$ fast Count-Min Sketch update
        ( metta_memo_entry(Fun, Arity, Gen, AVs, _, CachedResults)
        ->  member(Out, CachedResults)      % Hit: ZERO database modifications
        ;   findall(Result,
                ( append(AVs, [Result], RawArgs),
                  RawGoal =.. [Fun | RawArgs],
                  call(RawGoal) ),
                RawResults),
            list_to_set(RawResults, CachedResults),
            memo_store(Fun, Arity, Gen, AVs, CachedResults), % Miss: TinyLFU admission
            member(Out, CachedResults)
        )
    ;   ( memo_enabled(Fun),
          \+ memo_disabled_runtime(Fun),
          ground(AVs),
          \+ args_worth_caching(AVs)
        ->  runtime_disable(Fun)
        ;   true
        ),
        call(Goal)
    ).
