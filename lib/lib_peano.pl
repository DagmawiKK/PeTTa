:- use_module(library(clpfd)).

:- multifile metta_constrain_arg/3.
:- multifile metta_translate_literal/3.
:- multifile metta_translate_head/5.
:- multifile metta_translate_typed_arg/4.
:- multifile metta_get_type_candidate/2.
:- multifile metta_try_dispatch_call/4.
:- multifile metta_on_space_atom_added/2.
:- multifile metta_on_space_atom_removed/2.
:- multifile metta_present_term/2.

:- dynamic nat_space_index/3.

peano_default_config('dispatch-mode', strict).
peano_default_config('space-mode', mixed).
peano_default_config('display-mode', raw).
peano_default_config('display-threshold', 32).

peano_config_nbvar('dispatch-mode', peano_dispatch_mode).
peano_config_nbvar('space-mode', peano_space_mode).
peano_config_nbvar('display-mode', peano_display_mode).
peano_config_nbvar('display-threshold', peano_display_threshold).

normalize_peano_config_key('dispatch-mode', 'dispatch-mode').
normalize_peano_config_key(dispatch_mode, 'dispatch-mode').
normalize_peano_config_key('space-mode', 'space-mode').
normalize_peano_config_key(space_mode, 'space-mode').
normalize_peano_config_key('display-mode', 'display-mode').
normalize_peano_config_key(display_mode, 'display-mode').
normalize_peano_config_key('display-threshold', 'display-threshold').
normalize_peano_config_key(display_threshold, 'display-threshold').

valid_peano_config('dispatch-mode', strict).
valid_peano_config('dispatch-mode', compat).
valid_peano_config('space-mode', mixed).
valid_peano_config('space-mode', canonical).
valid_peano_config('display-mode', raw).
valid_peano_config('display-mode', surface).
valid_peano_config('display-mode', compact).
valid_peano_config('display-threshold', N) :-
    integer(N),
    N >= 0.

peano_get_config(KeyIn, Value) :-
    normalize_peano_config_key(KeyIn, Key),
    peano_config_nbvar(Key, Name),
    with_mutex(peano_config_mutex,
               ( catch(nb_getval(Name, Stored), _, fail)
               -> Value = Stored
               ; peano_default_config(Key, Value)
               )).

peano_set_config(KeyIn, Value) :-
    normalize_peano_config_key(KeyIn, Key),
    valid_peano_config(Key, Value),
    peano_config_nbvar(Key, Name),
    with_mutex(peano_config_mutex, nb_setval(Name, Value)).

peano_dispatch_mode(Mode) :-
    peano_get_config('dispatch-mode', Mode).

peano_space_mode(Mode) :-
    peano_get_config('space-mode', Mode).

peano_display_mode(Mode) :-
    peano_get_config('display-mode', Mode).

peano_display_threshold(Threshold) :-
    peano_get_config('display-threshold', Threshold).

'set-peano-config'(Key, Value, true) :-
    peano_set_config(Key, Value).

'get-peano-config'(Key, Value) :-
    peano_get_config(Key, Value).

metta_constrain_arg(Input, peano_int(0), []) :-
    nonvar(Input),
    Input == 'Z',
    !.
metta_constrain_arg(Input, peano_int(N), Goals) :-
    nonvar(Input),
    Input = [H|T],
    nonvar(H),
    H == 'S',
    T = [X],
    !,
    constrain_args(X, InnerOut, InnerGoals),
    Goals = [ N #> 0,
              M #= N - 1,
              InnerOut = peano_int(M)
            | InnerGoals ].

metta_translate_literal(X, [], peano_int(0)) :-
    nonvar(X),
    X == 'Z'.

metta_translate_head('S', [Arg], GsH, Goals, Out) :-
    translate_expr(Arg, GsArg, ArgOut),
    ( nonvar(ArgOut), ArgOut = peano_int(K), integer(K) ->
        K >= 0,
        append(GsH, GsArg, Inner),
        N is K + 1,
        Out = peano_int(N),
        Goals = Inner
    ;
        Out = peano_int(N),
        append(GsH,
               [ ArgOut = peano_int(K2),
                 ( integer(K2)
                   -> K2 >= 0
                   ;  K2 #>= 0 ),
                 ( integer(K2)
                   -> N is K2 + 1
                   ;  N #= K2 + 1 )
               ],
               Inner),
        append(Inner, GsArg, Goals)
    ).
metta_translate_head(fromNumber, [Arg], GsH, GsH, peano_int(Arg)) :-
    number(Arg).
metta_translate_head('peano.fromNumber', [Arg], GsH, GsH, peano_int(Arg)) :-
    number(Arg).
metta_translate_head(toNumber, [Arg], GsH, Goals, Out) :-
    translate_expr(Arg, GsArg, ArgOut),
    append(GsH, GsArg, Inner),
    append(Inner, [peano_to_number(ArgOut, Out)], Goals).
metta_translate_head('peano.toNumber', [Arg], GsH, Goals, Out) :-
    translate_expr(Arg, GsArg, ArgOut),
    append(GsH, GsArg, Inner),
    append(Inner, [peano_to_number(ArgOut, Out)], Goals).
metta_translate_head('nat-match', [Space, Pattern, Body], GsH, Goals, Out) :-
    translate_expr(Space, GsSpace, SpaceVal),
    Goal =.. ['nat-match', SpaceVal, Pattern, Body, Out],
    append(GsH, GsSpace, AllGoals),
    append(AllGoals, [Goal], Goals).
metta_translate_head('nat-has-atom', [Space, Atom], GsH, Goals, Out) :-
    translate_expr(Space, GsSpace, SpaceVal),
    Goal =.. ['nat-has-atom', SpaceVal, Atom, Out],
    append(GsH, GsSpace, AllGoals),
    append(AllGoals, [Goal], Goals).

metta_translate_typed_arg(A, 'Nat', [], peano_int(A)) :-
    number(A).

metta_get_type_candidate(peano_int(_), 'Nat').

metta_try_dispatch_call(Fun, Args, Out, Goal) :-
    peano_dispatch_goal(Fun, Args, Out, Goal).

explicit_peano_dispatch_term(peano_int(_)).
explicit_peano_dispatch_term('Z').
explicit_peano_dispatch_term(['S', _]).

dispatch_compatible_term(Term) :-
    var(Term),
    !.
dispatch_compatible_term(Term) :-
    explicit_peano_dispatch_term(Term).

peano_numeric_candidate(Vals) :-
    \+ ( member(V, Vals), number(V) ),
    peano_dispatch_mode(Mode),
    peano_numeric_candidate(Mode, Vals).

peano_numeric_candidate(strict, Vals) :-
    maplist(dispatch_compatible_term, Vals),
    member(V, Vals),
    explicit_peano_dispatch_term(V),
    !.
peano_numeric_candidate(compat, Vals) :-
    maplist(dispatch_compatible_term, Vals),
    member(V, Vals),
    ( explicit_peano_dispatch_term(V)
    ; var(V)
    ),
    !.

peano_compare_candidate(A, B) :-
    \+ number(A),
    \+ number(B),
    peano_numeric_candidate([A, B]).

peano_dispatch_goal('+', [A, B], Out, peano_plus(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal('-', [A, B], Out, peano_minus(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal('*', [A, B], Out, peano_times(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal('%', [A, B], Out, peano_mod(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal(min, [A, B], Out, peano_min(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal(max, [A, B], Out, peano_max(A, B, Out)) :-
    peano_numeric_candidate([A, B, Out]).
peano_dispatch_goal('<', [A, B], Out, peano_lt(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('<=', [A, B], Out, peano_lte(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('>', [A, B], Out, peano_gt(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('>=', [A, B], Out, peano_gte(A, B, Out)) :-
    peano_compare_candidate(A, B).

peano_nat_value(Term, N) :-
    ( var(Term)
    -> Term = peano_int(N)
    ; normalize_peano_if_needed(Term, Canonical, Goals),
      call_goals(Goals),
      Canonical = peano_int(N)
    ),
    N #>= 0.

peano_to_number(Term, Out) :-
    peano_nat_value(Term, N),
    Out = N.

peano_plus(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    IO #= IA + IB.

peano_minus(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    IO #= IA - IB.

peano_times(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    IO #= IA * IB.

peano_div(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    IB #> 0,
    R #>= 0,
    R #< IB,
    IA #= IO * IB + R.

peano_mod(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    IB #> 0,
    Q #>= 0,
    IO #< IB,
    IA #= Q * IB + IO.

peano_min(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    ( IA #=< IB #/\ IO #= IA )
    #\/
    ( IA #> IB #/\ IO #= IB ).

peano_max(A, B, Out) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    peano_nat_value(Out, IO),
    ( IA #>= IB #/\ IO #= IA )
    #\/
    ( IA #< IB #/\ IO #= IB ).

peano_lt(A, B, true) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    IA #< IB,
    !.
peano_lt(_, _, false).

peano_lte(A, B, true) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    IA #=< IB,
    !.
peano_lte(_, _, false).

peano_gt(A, B, true) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    IA #> IB,
    !.
peano_gt(_, _, false).

peano_gte(A, B, true) :-
    peano_nat_value(A, IA),
    peano_nat_value(B, IB),
    IA #>= IB,
    !.
peano_gte(_, _, false).

normalize_peano_data(Input, peano_int(0), []) :-
    nonvar(Input),
    Input == 'Z',
    !.
normalize_peano_data(Input, peano_int(N), []) :-
    nonvar(Input),
    Input = peano_int(N),
    !.
normalize_peano_data(Input, peano_int(N), Goals) :-
    nonvar(Input),
    Input = [H|T],
    nonvar(H),
    H == 'S',
    T = [X],
    !,
    normalize_peano_data(X, InnerOut, InnerGoals),
    Goals = [ N #> 0,
              M #= N - 1,
              InnerOut = peano_int(M)
            | InnerGoals ].
normalize_peano_data(X, X, []) :-
    ( var(X)
    ; atomic(X)
    ; X = partial(_, _)
    ),
    !.
normalize_peano_data([], [], []) :- !.
normalize_peano_data([H|T], [NH|NT], Goals) :-
    normalize_peano_data(H, NH, GH),
    normalize_peano_data(T, NT, GT),
    append(GH, GT, Goals).

present_peano_nat(compact, _, N, ['fromNumber', N]) :-
    integer(N),
    N >= 0.
present_peano_nat(surface, Threshold, N, ['fromNumber', N]) :-
    integer(N),
    N >= 0,
    N > Threshold,
    !.
present_peano_nat(surface, _, 0, 'Z') :- !.
present_peano_nat(surface, Threshold, N, ['S', Inner]) :-
    integer(N),
    N > 0,
    M is N - 1,
    present_peano_nat(surface, Threshold, M, Inner).

present_peano_term_for_mode(_, X, X) :-
    ( var(X)
    ; atomic(X),
      X \= peano_int(_)
    ; X = partial(_, _)
    ),
    !.
present_peano_term_for_mode(Mode, peano_int(N), Presented) :-
    integer(N),
    N >= 0,
    !,
    peano_display_threshold(Threshold),
    present_peano_nat(Mode, Threshold, N, Presented).
present_peano_term_for_mode(_, peano_int(N), peano_int(N)) :- !.
present_peano_term_for_mode(_, [], []) :- !.
present_peano_term_for_mode(Mode, [H|T], [PH|PT]) :-
    present_peano_term_for_mode(Mode, H, PH),
    present_peano_term_for_mode(Mode, T, PT).

present_peano_for_display(Input, Out) :-
    peano_display_mode(Mode0),
    ( Mode0 == raw
    -> Mode = surface
    ; Mode = Mode0
    ),
    present_peano_term_for_mode(Mode, Input, Out).

metta_present_term(Term, Presented) :-
    peano_display_mode(Mode),
    Mode \== raw,
    present_peano_term_for_mode(Mode, Term, Presented).

is_code_atom(Atom) :-
    nonvar(Atom),
    Atom = [Head|_],
    memberchk(Head, ['=', ':']).

contains_surface_peano_syntax(Input) :-
    nonvar(Input),
    ( Input == 'Z'
    ; Input = [H|_],
      nonvar(H),
      H == 'S'
    ; Input = [H|T],
      ( contains_surface_peano_syntax(H)
      ; contains_surface_peano_syntax(T)
      )
    ).

contains_any_peano_marker(Input) :-
    nonvar(Input),
    ( Input = peano_int(_)
    ; Input == 'Z'
    ; Input = [H|_],
      nonvar(H),
      H == 'S'
    ; Input = [H|T],
      ( contains_any_peano_marker(H)
      ; contains_any_peano_marker(T)
      )
    ).

normalize_peano_if_needed(Input, Out, Goals) :-
    ( contains_surface_peano_syntax(Input)
    -> normalize_peano_data(Input, Out, Goals)
    ; Out = Input,
      Goals = []
    ).

'nat-normalize'(Input, Out) :-
    normalize_peano_if_needed(Input, Out, Goals),
    call_goals(Goals).

'nat-present'(Input, Out) :-
    present_peano_for_display(Input, Out).

'nat-to-number'(Input, Out) :-
    peano_to_number(Input, Out).

'nat-div'(A, B, Out) :-
    peano_div(A, B, Out).

'nat-mod'(A, B, Out) :-
    peano_mod(A, B, Out).

'nat-min'(A, B, Out) :-
    peano_min(A, B, Out).

'nat-max'(A, B, Out) :-
    peano_max(A, B, Out).

nat_indexable_atom(RawAtom, CanonicalAtom) :-
    \+ is_code_atom(RawAtom),
    contains_any_peano_marker(RawAtom),
    normalize_peano_if_needed(RawAtom, CanonicalAtom, Goals),
    call_goals(Goals).

metta_on_space_atom_added(Space, Atom) :-
    ( nat_indexable_atom(Atom, CanonicalAtom)
    -> assertz(nat_space_index(Space, CanonicalAtom, Atom))
    ; true ).

metta_on_space_atom_removed(Space, Atom) :-
    ( nat_indexable_atom(Atom, CanonicalAtom)
    -> retractall(nat_space_index(Space, CanonicalAtom, Atom))
    ; true ).

peano_space_mutex_name(Space, Mutex) :-
    term_hash(Space, Hash),
    format(atom(Mutex), 'space_mutex_~w', [Hash]).

with_peano_space_lock(Space, Goal) :-
    peano_space_mutex_name(Space, Mutex),
    with_mutex(Mutex, Goal).

'nat-reindex-space'(Space, true) :-
    with_peano_space_lock(
        Space,
        (
            retractall(nat_space_index(Space, _, _)),
            forall(
                'get-atoms'(Space, Atom),
                ( nat_indexable_atom(Atom, CanonicalAtom)
                -> assertz(nat_space_index(Space, CanonicalAtom, Atom))
                ; true
                )
            )
        )
    ).

nat_prepare_pattern(Pattern, PatternNorm, PatternGoals) :-
    copy_term(Pattern, PatternCopy),
    normalize_peano_if_needed(PatternCopy, PatternNorm, PatternGoals).

nat_prepare_query(Pattern, Body, PatternNorm, PatternGoals, BodyNorm, BodyGoals) :-
    copy_term([Pattern, Body], [PatternCopy, BodyCopy]),
    normalize_peano_if_needed(PatternCopy, PatternNorm, PatternGoals),
    normalize_peano_if_needed(BodyCopy, BodyNorm, BodyGoals).

nat_query_prefers_index(_, _) :-
    peano_space_mode(canonical),
    !.
nat_query_prefers_index(PatternNorm, BodyNorm) :-
    ( contains_any_peano_marker(PatternNorm)
    ; contains_any_peano_marker(BodyNorm)
    ).

nat_match_index_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out) :-
    with_peano_space_lock(
        Space,
        (
            nat_space_index(Space, PatternNorm, _),
            call_goals(PatternGoals),
            call_goals(BodyGoals),
            Out = BodyNorm
        )
    ).

nat_match_index_available(Space, PatternNorm, PatternGoals) :-
    copy_term([PatternNorm, PatternGoals], [PatternCopy, PatternGoalsCopy]),
    with_peano_space_lock(
        Space,
        once((
            nat_space_index(Space, PatternCopy, _),
            call_goals(PatternGoalsCopy)
        ))
    ).

nat_match_fast_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out) :-
    match(Space, PatternNorm, BodyNorm, Out),
    call_goals(PatternGoals),
    call_goals(BodyGoals).

nat_match_fast_available(Space, PatternNorm, PatternGoals) :-
    copy_term([PatternNorm, PatternGoals], [PatternCopy, PatternGoalsCopy]),
    once((
        match(Space, PatternCopy, true, _),
        call_goals(PatternGoalsCopy)
    )).

nat_match_fallback_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out) :-
    'get-atoms'(Space, StoredAtom),
    contains_surface_peano_syntax(StoredAtom),
    normalize_peano_data(StoredAtom, StoredNorm, StoredGoals),
    call_goals(StoredGoals),
    PatternNorm = StoredNorm,
    call_goals(PatternGoals),
    call_goals(BodyGoals),
    Out = BodyNorm.

nat_has_atom_fast_prepared(Space, PatternNorm, PatternGoals) :-
    match(Space, PatternNorm, true, _),
    call_goals(PatternGoals).

nat_has_atom_index_prepared(Space, PatternNorm, PatternGoals) :-
    with_peano_space_lock(
        Space,
        (
            nat_space_index(Space, PatternNorm, _),
            call_goals(PatternGoals)
        )
    ).

nat_has_atom_fallback_prepared(Space, PatternNorm, PatternGoals) :-
    'get-atoms'(Space, StoredAtom),
    contains_surface_peano_syntax(StoredAtom),
    normalize_peano_data(StoredAtom, StoredNorm, StoredGoals),
    call_goals(StoredGoals),
    PatternNorm = StoredNorm,
    call_goals(PatternGoals).

'nat-add-atom'(Space, Atom, Out) :-
    ( is_code_atom(Atom)
    -> 'add-atom'(Space, Atom, Out)
    ; normalize_peano_if_needed(Atom, AtomOut, Goals),
      call_goals(Goals),
      ( catch(nb_getval(peano_debug, true), _, fail)
        -> swrite(AtomOut, S), format("[peano-debug] adding: ~w~n", [S])
        ; true ),
      'add-atom'(Space, AtomOut, Out)
    ).

'nat-remove-atom'(Space, Atom, Out) :-
    ( is_code_atom(Atom)
    -> 'remove-atom'(Space, Atom, Out)
    ; normalize_peano_if_needed(Atom, AtomOut, Goals),
      call_goals(Goals),
      'remove-atom'(Space, AtomOut, Out)
    ).

'nat-match'(Space, Pattern, Body, Out) :-
    nat_prepare_query(Pattern, Body, PatternNorm, PatternGoals, BodyNorm, BodyGoals),
    peano_space_mode(Mode),
    nat_match_dispatch(Mode, Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out).

nat_match_dispatch(canonical, Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out) :-
    nat_match_index_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out).
nat_match_dispatch(mixed, Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out) :-
    ( nat_query_prefers_index(PatternNorm, BodyNorm),
      nat_match_index_available(Space, PatternNorm, PatternGoals)
    -> nat_match_index_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out)
    ; nat_match_fast_available(Space, PatternNorm, PatternGoals)
    -> nat_match_fast_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out)
    ; nat_match_fallback_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out)
    ).

'nat-has-atom'(Space, Atom, true) :-
    nat_prepare_pattern(Atom, PatternNorm, PatternGoals),
    peano_space_mode(Mode),
    nat_has_atom_dispatch(Mode, Space, PatternNorm, PatternGoals),
    !.
'nat-has-atom'(_, _, false).

nat_has_atom_dispatch(canonical, Space, PatternNorm, PatternGoals) :-
    once(nat_has_atom_index_prepared(Space, PatternNorm, PatternGoals)).
nat_has_atom_dispatch(mixed, Space, PatternNorm, PatternGoals) :-
    ( nat_query_prefers_index(PatternNorm, true),
      nat_match_index_available(Space, PatternNorm, PatternGoals)
    -> once(nat_has_atom_index_prepared(Space, PatternNorm, PatternGoals))
    ; nat_match_fast_available(Space, PatternNorm, PatternGoals)
    -> once(nat_has_atom_fast_prepared(Space, PatternNorm, PatternGoals))
    ; once(nat_has_atom_fallback_prepared(Space, PatternNorm, PatternGoals))
    ).
