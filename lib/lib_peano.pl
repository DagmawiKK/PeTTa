:- use_module(library(clpfd)).

:- multifile metta_constrain_arg/3.
:- multifile metta_translate_literal/3.
:- multifile metta_translate_head/5.
:- multifile metta_translate_typed_arg/4.
:- multifile metta_get_type_candidate/2.
:- multifile metta_try_dispatch_call/4.

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
    Goals = [ ( integer(N)
                -> N > 0,
                   M is N - 1
                ;  N #> 0,
                   M #= N - 1
              ),
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

peano_dispatch_goal('+', [A, B], Out, peano_plus(A, B, Out)) :-
    peano_arithmetic_candidate([A, B, Out]).
peano_dispatch_goal('-', [A, B], Out, peano_minus(A, B, Out)) :-
    peano_arithmetic_candidate([A, B, Out]).
peano_dispatch_goal('*', [A, B], Out, peano_times(A, B, Out)) :-
    peano_arithmetic_candidate([A, B, Out]).
peano_dispatch_goal('<', [A, B], Out, peano_lt(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('<=', [A, B], Out, peano_lte(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('>', [A, B], Out, peano_gt(A, B, Out)) :-
    peano_compare_candidate(A, B).
peano_dispatch_goal('>=', [A, B], Out, peano_gte(A, B, Out)) :-
    peano_compare_candidate(A, B).

peano_arithmetic_candidate(Vals) :-
    \+ ( member(V, Vals), number(V) ),
    member(V, Vals),
    peanoish(V).

peano_compare_candidate(A, B) :-
    \+ number(A),
    \+ number(B),
    peanoish(A),
    peanoish(B),
    nonvar(A),
    nonvar(B).

peanoish(peano_int(_)).
peanoish(V) :-
    var(V).

peano_int_value(peano_int(N), N).

peano_plus(A, B, Out) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    peano_int_value(Out, IO),
    IA #>= 0,
    IB #>= 0,
    IO #>= 0,
    IO #= IA + IB.

peano_minus(A, B, Out) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    peano_int_value(Out, IO),
    IA #>= 0,
    IB #>= 0,
    IO #>= 0,
    IO #= IA - IB.

peano_times(A, B, Out) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    peano_int_value(Out, IO),
    IA #>= 0,
    IB #>= 0,
    IO #>= 0,
    IO #= IA * IB.

peano_lt(A, B, true) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    IA #< IB,
    !.
peano_lt(_, _, false).

peano_lte(A, B, true) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    IA #=< IB,
    !.
peano_lte(_, _, false).

peano_gt(A, B, true) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
    IA #> IB,
    !.
peano_gt(_, _, false).

peano_gte(A, B, true) :-
    peano_int_value(A, IA),
    peano_int_value(B, IB),
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
    Goals = [ ( integer(N)
                -> N > 0,
                   M is N - 1
                ;  N #> 0,
                   M #= N - 1
              ),
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

present_peano_data(peano_int(0), 'Z').
present_peano_data(peano_int(N), ['S', Inner]) :-
    integer(N),
    N > 0,
    M is N - 1,
    present_peano_data(peano_int(M), Inner).
present_peano_data(X, X) :-
    ( var(X)
    ; atomic(X)
    ; X = partial(_, _)
    ).
present_peano_data([], []).
present_peano_data([H|T], [PH|PT]) :-
    present_peano_data(H, PH),
    present_peano_data(T, PT).

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

normalize_peano_if_needed(Input, Out, Goals) :-
    ( contains_surface_peano_syntax(Input)
    -> normalize_peano_data(Input, Out, Goals)
    ; Out = Input,
      Goals = []
    ).

nat_prepare_pattern(Pattern, PatternNorm, PatternGoals) :-
    copy_term(Pattern, PatternCopy),
    normalize_peano_if_needed(PatternCopy, PatternNorm, PatternGoals).

nat_prepare_query(Pattern, Body, PatternNorm, PatternGoals, BodyNorm, BodyGoals) :-
    copy_term([Pattern, Body], [PatternCopy, BodyCopy]),
    normalize_peano_if_needed(PatternCopy, PatternNorm, PatternGoals),
    normalize_peano_if_needed(BodyCopy, BodyNorm, BodyGoals).

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
      % Optional debug printing if nbval peano_debug is true
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
    ( nat_match_fast_available(Space, PatternNorm, PatternGoals)
    -> nat_match_fast_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out)
    ; nat_match_fallback_prepared(Space, PatternNorm, PatternGoals, BodyNorm, BodyGoals, Out)
    ).

'nat-has-atom'(Space, Atom, true) :-
    nat_prepare_pattern(Atom, PatternNorm, PatternGoals),
    ( nat_match_fast_available(Space, PatternNorm, PatternGoals)
    -> once(nat_has_atom_fast_prepared(Space, PatternNorm, PatternGoals))
    ; once(nat_has_atom_fallback_prepared(Space, PatternNorm, PatternGoals))
    ),
    !.
'nat-has-atom'(_, _, false).
