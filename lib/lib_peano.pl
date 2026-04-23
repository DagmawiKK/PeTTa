:- use_module(library(clpfd)).

:- multifile metta_constrain_arg/3.
:- multifile metta_translate_literal/3.
:- multifile metta_translate_head/5.
:- multifile metta_translate_typed_arg/4.
:- multifile metta_get_type_candidate/2.

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

metta_translate_typed_arg(A, 'Nat', [], peano_int(A)) :-
    number(A).

metta_get_type_candidate(peano_int(_), 'Nat').
