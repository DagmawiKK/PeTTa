%Pattern matching, structural and functional/relational constraints on arguments:
constrain_args(X, X, []) :- (var(X); atomic(X)), !.
constrain_args([F, A, B], Out, Goals) :- nonvar(F),
                                         F == cons,
                                         constrain_args(A, A1, G1),
                                         constrain_args(B, B1, G2),
                                         Out = [A1|B1],
                                         append(G1, G2, Goals), !.
constrain_args([F|Args], Var, Goals) :- atom(F),
                                        is_fun(F), !,
                                        translate_expr([F|Args], GoalsExpr, Var),
                                        flatten(GoalsExpr, Goals).
constrain_args(In, Out, Goals) :- maplist(constrain_args, In, Out, NestedGoalsList),
                                  flatten(NestedGoalsList, Goals), !.

%Flatten (= Head Body) MeTTa function into Prolog Clause:
translate_clause(Input, (Head :- BodyConj)) :- translate_clause(Input, (Head :- BodyConj), true).
translate_clause(Input, (Head :- BodyConj), ConstrainArgs) :-
                                               Input = [=, [F|Args0], BodyExpr],
                                               ( ConstrainArgs -> maplist(constrain_args, Args0, Args1, GoalsA),
                                                                  flatten(GoalsA,GoalsPrefix)
                                                                ; Args1 = Args0, GoalsPrefix = [] ),
                                               catch(nb_getval(F, Prev), _, Prev = []),
                                               nb_setval(F, [fun_meta(Args1, BodyExpr) | Prev]),
                                               translate_expr(BodyExpr, GoalsBody, ExpOut),
                                               (  nonvar(ExpOut) , ExpOut = partial(Base,Bound)
                                               -> current_predicate(Base/Arity), length(Bound, N), M is (Arity - N) - 1,
                                                  length(ExtraArgs, M), append([Bound,ExtraArgs,[Out]],CallArgs), Goal =.. [Base|CallArgs],
                                                  append(GoalsBody,[Goal],FinalGoals), append(Args1,ExtraArgs,HeadArgs)
                                               ; FinalGoals= GoalsBody , HeadArgs = Args1, Out = ExpOut ),
                                               append(HeadArgs, [Out], FinalArgs),
                                               Head =.. [F|FinalArgs],
                                               append(GoalsPrefix, FinalGoals, Goals),
                                               goals_list_to_conj(Goals, BodyConj).

%Print compiled clause:
maybe_print_compiled_clause(_, _, _) :- silent(true), !.
maybe_print_compiled_clause(Label, FormTerm, Clause) :-
    swrite(FormTerm, FormStr),
    format("\e[33m-->  ~w  -->~n\e[36m~w~n\e[33m--> prolog clause -->~n\e[32m", [Label, FormStr]),
    portray_clause(current_output, Clause),
    format("\e[33m^^^^^^^^^^^^^^^^^^^^^~n\e[0m").

%Conjunction builder, turning goals list to a flat conjunction:
goals_list_to_conj([], true)      :- !.
goals_list_to_conj([G], G)        :- !.
goals_list_to_conj([G|Gs], (G,R)) :- goals_list_to_conj(Gs, R).

% Negative cache for fun/1: skip straight to failure for atoms already known to not be functions.
% register_fun/1 retracts not_fun/1 entries when a function is newly registered.
is_fun(F) :- not_fun(F), !, fail.
is_fun(F) :- fun(F), !.
is_fun(F) :- assertz(not_fun(F)), fail.

% Runtime dispatcher: call F if it's a registered fun/1, else keep as list:
reduce([F|Args], Out) :- nonvar(F), atom(F), is_fun(F)
                         -> % --- Case 1: callable predicate ---
                            length(Args, N),
                            Arity is N + 1,
                            ( ( catch(arity(F, Arity), _, fail) ; current_predicate(F/Arity) ),
                              \+ (current_op(_, _, F), Arity =< 2)
                              -> append(Args,[Out],CallArgs),
                                 Goal =.. [F|CallArgs],
                                 catch(call(Goal),_,fail)
                               ; Out = partial(F,Args) )
                          ; % --- Case 2: partial closure ---
                            compound(F), F = partial(Base, Bound) -> append(Bound, Args, NewArgs),
                                                                     reduce([Base|NewArgs], Out)
                          ; % --- Case 3: leave unevaluated ---
                            Out = [F|Args].

%Calling reduce from aggregate function foldall needs this argument wrapping
agg_reduce(AF, Acc, Val, NewAcc) :- reduce([AF, Acc, Val], NewAcc).

%Combined expr translation to goals list
translate_expr_to_conj(Input, Conj, Out) :- translate_expr(Input, Goals, Out),
                                            goals_list_to_conj(Goals, Conj).

%Memoized type-chain lookup — avoids repeated space queries for the same function:
:- dynamic type_chains_cache/2.
get_type_chains(Fun, TypeChains) :-
    ( type_chains_cache(Fun, TypeChains)
      -> true
      ;  findall(TypeChain, catch(match('&self', [':', Fun, TypeChain], TypeChain, TypeChain), _, fail), TypeChains),
         assertz(type_chains_cache(Fun, TypeChains))
    ).

%Indexed fact table for O(1) rewriteable-op guard (SWI-Prolog JIT indexes this):
rewriteable_op('trace!').
rewriteable_op(unique).
rewriteable_op(union).
rewriteable_op(intersection).
rewriteable_op(subtraction).

%Special stream operation rewrite rules before main translation
rewrite_streamops(['trace!', Arg1, Arg2],
                  [progn, ['println!', Arg1], Arg2]).
rewrite_streamops([unique, Arg],
                  [call, [superpose, ['unique-atom', [collapse, Arg]]]]).
rewrite_streamops([union, [superpose|A], [superpose|B]],
                  [call, [superpose, ['union-atom', [collapse, [superpose|A]],
                                                    [collapse, [superpose|B]]]]]).
rewrite_streamops([intersection, [superpose|A], [superpose|B]],
                  [call, [superpose, ['intersection-atom', [collapse, [superpose|A]],
                                                           [collapse, [superpose|B]]]]]).
rewrite_streamops([subtraction, [superpose|A], [superpose|B]],
                  [call, [superpose, ['subtraction-atom', [collapse, [superpose|A]],
                                                          [collapse, [superpose|B]]]]]).
rewrite_streamops(X, X).

%Turn MeTTa code S-expression into goals list:
translate_expr(X, [], X)          :- ((var(X) ; atomic(X)) ; X = partial(_,_)), !.
translate_expr([H0|T0], Goals, Out) :-
        ( atom(H0), rewriteable_op(H0)
          -> rewrite_streamops([H0|T0], [H|T])
          ; H = H0, T = T0 ),
        ( atomic(H) -> HV = H, GsH = [] ; translate_expr(H, GsH, HV) ),
        ( atom(HV)
          -> translate_expr_dispatch(HV, T, GsH, Goals, Out)
          ; translate_expr_fallback(HV, T, GsH, Goals, Out) ).

%--- Indexed dispatch clauses (SWI-Prolog JIT builds hash table on arg 1) ---:
%--- Non-determinism ---:
translate_expr_dispatch(superpose, T, GsH, Goals, Out) :-
    T = [Args], is_list(Args), !,
    build_superpose_branches(Args, Out, Branches),
    disj_list(Branches, Disj),
    append(GsH, [Disj], Goals).
translate_expr_dispatch(collapse, T, GsH, Goals, Out) :-
    T = [E], !,
    translate_expr_to_conj(E, Conj, EV),
    append(GsH, [findall(EV, Conj, Out)], Goals).
translate_expr_dispatch(cut, T, GsH, Goals, Out) :-
    T = [], !,
    append(GsH, [(!)], Goals),
    Out = true.
translate_expr_dispatch(test, T, GsH, Goals, Out) :-
    T = [Expr, Expected], !,
    translate_expr_to_conj(Expr, Conj, Val),
    translate_expr(Expected, GsE, ExpVal),
    Goal1 = ( findall(Val, Conj, Results),
              (Results = [Actual] -> true
                                   ; Actual = Results ) ),
    append([GsH, [Goal1], GsE, [test(Actual, ExpVal, Out)]], Goals).
translate_expr_dispatch(once, T, GsH, Goals, Out) :-
    T = [X], !,
    translate_expr_to_conj(X, Conj, Out),
    append(GsH, [once(Conj)], Goals).
translate_expr_dispatch(hyperpose, T, GsH, Goals, Out) :-
    T = [L], !,
    ( nonvar(L), is_list(L)
      -> build_hyperpose_branches(L, Branches),
         append(GsH, [concurrent_and(member((Goal,Res), Branches), (call(Goal), Out = Res))], Goals)
      ; translate_expr(L, GsL, LV),
        append([GsH, GsL, [hyperpose_runtime(LV, Out)]], Goals) ).
translate_expr_dispatch(with_mutex, T, GsH, Goals, Out) :-
    T = [M, X], !,
    translate_expr_to_conj(X, Conj, Out),
    append(GsH, [with_mutex(M,Conj)], Goals).
translate_expr_dispatch(transaction, T, GsH, Goals, Out) :-
    T = [X], !,
    translate_expr_to_conj(X, Conj, Out),
    append(GsH, [transaction(Conj)], Goals).
%--- Sequential execution ---:
translate_expr_dispatch(progn, T, GsH, Goals, Out) :- !,
    translate_args(T, GsList, Outs),
    append(GsH, GsList, Goals),
    last(Outs, Out).
translate_expr_dispatch(prog1, T, GsH, Goals, Out) :- !,
    T = [First|Rest],
    translate_expr(First, GsF, Out),
    translate_args(Rest, GsRest, _),
    append([GsH, GsF, GsRest], Goals).
%--- Conditionals ---:
translate_expr_dispatch(if, T, GsH, Goals, Out) :-
    T = [Cond, Then], !,
    translate_expr_to_conj(Cond, ConC, Cv),
    translate_expr_to_conj(Then, ConT, Tv),
    build_branch(ConT, Tv, Out, BT),
    ( ConC == true -> append(GsH, [ ( Cv == true -> BT ) ], Goals)
                    ; append(GsH, [ ( ConC, ( Cv == true -> BT ) ) ], Goals) ).
translate_expr_dispatch(if, T, GsH, Goals, Out) :-
    T = [Cond, Then, Else], !,
    translate_expr_to_conj(Cond, ConC, Cv),
    translate_expr_to_conj(Then, ConT, Tv),
    translate_expr_to_conj(Else, ConE, Ev),
    build_branch(ConT, Tv, Out, BT),
    build_branch(ConE, Ev, Out, BE),
    ( ConC == true -> append(GsH, [ (Cv == true -> BT ; BE) ], Goals)
                    ; append(GsH, [ (ConC, (Cv == true -> BT ; BE)) ], Goals) ).
translate_expr_dispatch(case, T, GsH, Goals, Out) :-
    T = [KeyExpr, PairsExpr], !,
    ( select(Found0, PairsExpr, Rest0),
      subsumes_term(['Empty', _], Found0),
      Found0 = ['Empty', DefaultExpr],
      NormalCases = Rest0
      -> translate_expr_to_conj(KeyExpr, GkConj, Kv),
         translate_case(NormalCases, Kv, Out, CaseGoal, KeyGoal),
         translate_expr_to_conj(DefaultExpr, ConD, DOut),
         build_branch(ConD, DOut, Out, DefaultThen),
         Combined = ( (GkConj, CaseGoal) ;
                      \+ GkConj, DefaultThen ),
         append([GsH, KeyGoal, [Combined]], Goals)
       ; translate_expr(KeyExpr, Gk, Kv),
         translate_case(PairsExpr, Kv, Out, IfGoal, KeyGoal),
         append([GsH, Gk, KeyGoal, [IfGoal]], Goals) ).
%--- Unification constructs ---:
translate_expr_dispatch(let, T, GsH, Goals, Out) :-
    T = [Pat, Val, In], !,
    translate_expr(Pat, Gp, Pv),
    translate_expr(Val, Gv, V),
    translate_expr(In,  Gi, Out),
    append([GsH,[(Pv=V)],Gp,Gv,Gi], Goals).
translate_expr_dispatch(chain, T, GsH, Goals, Out) :-
    T = [Pat, Val, In], !,
    translate_expr(Pat, Gp, Pv),
    translate_expr(Val, Gv, V),
    translate_expr(In,  Gi, Out),
    append([GsH,[(Pv=V)],Gp,Gv,Gi], Goals).
translate_expr_dispatch('let*', T, _GsH, Goals, Out) :-
    T = [Binds, Body], !,
    letstar_to_rec_let(Binds, Body, RecLet),
    translate_expr(RecLet, Goals, Out).
translate_expr_dispatch(sealed, T, _GsH, Goals, Out) :-
    T = [Vars, Expr], !,
    translate_expr_to_conj(Expr, Con, Val),
    Goals = [copy_term(Vars,[Con,Val],_,[Ncon,Out]),Ncon].
%--- Iterating over non-deterministic generators without reification ---:
translate_expr_dispatch('forall', T, GsH, Goals, Out) :-
    T = [GF, TF], !,
    ( is_list(GF) -> GF = [GFH|GFA],
                      translate_expr(GFH, GsGFH, GFHV),
                      translate_args(GFA, GsGFA, GFAv),
                      append(GsGFH, GsGFA, GsGF),
                      GenList = [GFHV|GFAv]
                    ; translate_expr(GF, GsGF, GFHV),
                      GenList = [GFHV] ),
    translate_expr(TF, GsTF, TFHV),
    TestList = [TFHV, V],
    goals_list_to_conj(GsGF, GPre),
    GenGoal = (GPre, reduce(GenList, V)),
    append([GsH, GsTF, [( forall(GenGoal, ( reduce(TestList, Truth), Truth == true )) -> Out = true ; Out = false )]], Goals).
translate_expr_dispatch('foldall', T, GsH, Goals, Out) :-
    T = [AF, GF, InitS], !,
    translate_expr_to_conj(InitS, ConjInit, Init),
    translate_expr(AF, GsAF, AFV),
    ( GF = [M|_], (M==match ; M==let ; M=='let*') -> LambdaGF = ['|->', [], GF],
                                                      translate_expr(LambdaGF, GsGF, GFHV),
                                                      GenList = [GFHV]
    ; is_list(GF) -> GF = [GFH|GFA],
                     translate_expr(GFH, GsGFH, GFHV),
                     translate_args(GFA, GsGFA, GFAv),
                     append(GsGFH, GsGFA, GsGF),
                     GenList = [GFHV|GFAv]
                   ; translate_expr(GF, GsGF, GFHV),
                     GenList = [GFHV] ),
    append([GsH, GsAF, GsGF, [ConjInit, foldall(agg_reduce(AFV, V), reduce(GenList, V), Init, Out)]], Goals).
%--- Higher-order functions with named helper predicates (no YALL closures) ---:
translate_expr_dispatch('foldl-atom', T, GsH, Goals, Out) :-
    T = [List, Init, AccVar, XVar, Body], !,
    translate_expr_to_conj(List, ConjList, L),
    translate_expr_to_conj(Init, ConjInit, InitV),
    translate_expr_to_conj(Body, BodyConj, BG),
    exclude(==(true), [ConjList, ConjInit], CleanConjs),
    append(GsH, CleanConjs, GsMid),
    term_variables(XVar-AccVar, LambdaPs),
    term_variables(Body, AllBVars),
    exclude({LambdaPs}/[V]>>memberchk_eq(V, LambdaPs), AllBVars, FreeVars),
    next_lambda_name(HelpF),
    append(FreeVars, [XVar, AccVar, NewAcc], HArgs),
    HHead =.. [HelpF|HArgs],
    HBody = (BodyConj, (number(BG) -> NewAcc is BG ; NewAcc = BG)),
    assertz((HHead :- HBody)),
    ( FreeVars == [] -> FoldCall = foldl(HelpF, L, InitV, Out)
    ; HTerm =.. [HelpF|FreeVars], FoldCall = foldl(HTerm, L, InitV, Out) ),
    append(GsMid, [FoldCall], Goals).
translate_expr_dispatch('map-atom', T, GsH, Goals, Out) :-
    T = [List, XVar, Body], !,
    translate_expr_to_conj(List, ConjList, L),
    translate_expr_to_conj(Body, BodyCallConj, BodyCall),
    exclude(==(true), [ConjList], CleanConjs),
    append(GsH, CleanConjs, GsMid),
    term_variables(XVar, XVs),
    term_variables(Body, AllBVars),
    exclude({XVs}/[V]>>memberchk_eq(V, XVs), AllBVars, FreeVars),
    next_lambda_name(HelpF),
    append(FreeVars, [XVar, MOut], HArgs),
    HHead =.. [HelpF|HArgs],
    HBody = (BodyCallConj, (number(BodyCall) -> MOut is BodyCall ; MOut = BodyCall)),
    assertz((HHead :- HBody)),
    ( FreeVars == [] -> MapCall = maplist(HelpF, L, Out)
    ; HTerm =.. [HelpF|FreeVars], MapCall = maplist(HTerm, L, Out) ),
    append(GsMid, [MapCall], Goals).
translate_expr_dispatch('filter-atom', T, GsH, Goals, Out) :-
    T = [List, XVar, Cond], !,
    translate_expr_to_conj(List, ConjList, L),
    translate_expr_to_conj(Cond, CondConj, CondGoal),
    exclude(==(true), [ConjList], CleanConjs),
    append(GsH, CleanConjs, GsMid),
    term_variables(XVar, XVs),
    term_variables(Cond, AllCVars),
    exclude({XVs}/[V]>>memberchk_eq(V, XVs), AllCVars, FreeVars),
    next_lambda_name(HelpF),
    append(FreeVars, [XVar], HArgs),
    HHead =.. [HelpF|HArgs],
    HBody = (CondConj, CondGoal),
    assertz((HHead :- HBody)),
    ( FreeVars == [] -> FilterCall = include(HelpF, L, Out)
    ; HTerm =.. [HelpF|FreeVars], FilterCall = include(HTerm, L, Out) ),
    append(GsMid, [FilterCall], Goals).
%--- Lambdas ---:
translate_expr_dispatch('|->', T, GsH, Goals, Out) :-
    T = [Args, Body], !,
    next_lambda_name(F),
    term_variables(Body, AllVars),
    term_variables(Args, ArgVars),
    exclude({ArgVars}/[V]>>memberchk_eq(V, ArgVars), AllVars, FreeVars),
    append(FreeVars, Args, FullArgs),
    translate_clause([=, [F|FullArgs], Body], Clause),
    register_fun(F),
    assertz(Clause),
    format(atom(Label), "metta lambda (~w)", [F]),
    maybe_print_compiled_clause(Label, ['|->', Args, Body], Clause),
    length(FullArgs, N),
    Arity is N + 1,
    assertz(arity(F, Arity)),
    ( FreeVars == [] -> Out = F
                       ; Out = partial(F, FreeVars) ),
    Goals = GsH.
%--- Spaces ---:
translate_expr_dispatch('add-atom', T, GsH, Goals, Out) :-
    T = [_,_], !,
    append(T, [Out], RawArgs),
    Goal =.. ['add-atom'|RawArgs],
    append(GsH, [Goal], Goals).
translate_expr_dispatch('remove-atom', T, GsH, Goals, Out) :-
    T = [_,_], !,
    append(T, [Out], RawArgs),
    Goal =.. ['remove-atom'|RawArgs],
    append(GsH, [Goal], Goals).
translate_expr_dispatch(match, T, _GsH, Goals, Out) :-
    T = [Space, Pattern, Body], !,
    translate_expr(Space, G1, S),
    translate_expr(Body, GsB, Out),
    append(G1, [match(S, Pattern, Out, Out)], G2),
    append(G2, GsB, Goals).
%--- Predicate to compiled goal ---:
translate_expr_dispatch(translatePredicate, T, GsH, Goals, _Out) :-
    T = [Expr], !,
    Expr = [S|Args],
    translate_args(Args, GsArgs, ArgsOut),
    Goal =.. [S|ArgsOut],
    append([GsH, GsArgs, [Goal]], Goals).
%--- Manual dispatch options ---:
translate_expr_dispatch(call, T, GsH, Goals, Out) :-
    T = [Expr], !,
    Expr = [F|Args],
    translate_args(Args, GsArgs, ArgsOut),
    append(ArgsOut, [Out], CallArgs),
    Goal =.. [F|CallArgs],
    append([GsH, GsArgs, [Goal]], Goals).
translate_expr_dispatch(reduce, T, GsH, Goals, Out) :-
    T = [Expr], !,
    ( var(Expr) -> translate_expr(Expr, GsH, ExprOut),
                   Goals = [reduce(ExprOut, Out)|GsH]
                 ; Expr = [F|Args],
                   translate_args(Args, GsArgs, ArgsOut),
                   ExprOut = [F|ArgsOut],
                   append([GsH, GsArgs, [reduce(ExprOut, Out)]], Goals) ).
translate_expr_dispatch(eval, T, GsH, Goals, Out) :-
    T = [Arg], !,
    Goal = eval(Arg, Out),
    append(GsH, [Goal], Goals).
translate_expr_dispatch(quote, T, GsH, Goals, Out) :-
    T = [Expr], !,
    Out = Expr,
    Goals = GsH.
translate_expr_dispatch('catch', T, GsH, Goals, Out) :-
    T = [Expr], !,
    translate_expr(Expr, GsExpr, ExprOut),
    goals_list_to_conj(GsExpr, Conj),
    Goal = catch((Conj, Out = ExprOut),
                 Exception,
                 (Exception = error(Type, Ctx) -> Out = ['Error', Type, Ctx]
                                                ; Out = ['Error', Exception])),
    append(GsH, [Goal], Goals).
%--- Catch-all: delegate to fallback ---:
translate_expr_dispatch(HV, T, GsH, Goals, Out) :-
    translate_expr_fallback(HV, T, GsH, Goals, Out).

%--- Fallback: translator rules, known functions, data, dynamic dispatch ---:
translate_expr_fallback(HV, T, GsH, Goals, Out) :-
    ( nonvar(HV), translator_rule(HV)
      -> ( catch(match('&self', [':', HV, TypeChain], TypeChain, TypeChain), _, fail)
           -> TypeChain = [->|Xs],
              append(ArgTypes, [_], Xs),
              translate_args_by_type(T, ArgTypes, GsT, T1)
            ; translate_args(T, GsT, T1) ),
         append(T1,[Gs],Args),
         HookCall =.. [HV|Args],
         call(HookCall),
         translate_expr(Gs, GsE, Out),
         append([GsH,GsT,GsE],Goals)
    ; translate_args(T, GsT, AVs),
      append(GsH, GsT, Inner),
      ( ( atom(HV), is_fun(HV), Fun = HV, AllAVs = AVs, IsPartial = false
        ; compound(HV), HV = partial(Fun, Bound), append(Bound,AVs,AllAVs), IsPartial = true
        )
        -> get_type_chains(Fun, TypeChains),
           ( TypeChains \= []
             -> maplist({Fun,T,GsH,IsPartial,Bound,Out}/[TypeChain,BranchGoal]>>(
                        typed_functioncall_branch(Fun, TypeChain, T, GsH, IsPartial, Bound, Out, BranchGoal)), TypeChains, Branches),
                disj_list(Branches, Disj),
                Goals = [Disj]
          ; build_call_or_partial(Fun, AllAVs, Out, Inner, [], Goals))
      ; ( atomic(HV), \+ atom(HV) ; atom(HV), \+ is_fun(HV) ) -> Out = [HV|AVs],
                                                                Goals = Inner
      ; is_list(HV) -> eval_data_term(HV, Gd, HV1),
                       append(Inner, Gd, Goals),
                       Out = [HV1|AVs]
      ; append(Inner, [reduce([HV|AVs], Out)], Goals) ) ).

%Generate actual function call or partial if arity not complete:
build_call_or_partial(Fun, AVs, Out, Inner, Extra, Goals) :- length(AVs, N),
                                                             Arity is N + 1,
                                                             ( maybe_specialize_call(Fun, AVs, Out, Goal)
                                                               -> append(Inner, [Goal|Extra], Goals)
                                                                ; ( ( current_predicate(Fun/Arity) ; catch(arity(Fun, Arity), _, fail) ),
                                                                     \+ ( current_op(_, _, Fun), Arity =< 2 ) )
                                                                  -> append(AVs, [Out], Args),
                                                                     Goal =.. [Fun|Args],
                                                                     append(Inner, [Goal|Extra], Goals)
                                                                   ; Out = partial(Fun, AVs),
                                                                     append(Inner, Extra, Goals) ).

%Type function call generation, returns function call plus typechecks for input and output:
typed_functioncall_branch(Fun, TypeChain, T, GsH, IsPartial, Bound, Out, BranchGoal) :-
    TypeChain = [->|Xs],
    append(ArgTypes, [OutType], Xs),
    translate_args_by_type(T, ArgTypes, GsT2, AVsTmp0),
    ( IsPartial -> append(Bound, AVsTmp0, AVsTmp) ; AVsTmp = AVsTmp0 ),
    append(GsH, GsT2, InnerTmp),
    ( (OutType == '%Undefined%' ; OutType == 'Atom')
       -> Extra = [] ; Extra = [('get-type'(Out, OutType) *-> true ; 'get-metatype'(Out, OutType))] ),
    build_call_or_partial(Fun, AVsTmp, Out, InnerTmp, Extra, GoalsList),
    goals_list_to_conj(GoalsList, BranchGoal).


%Selectively apply translate_args for non-Expression args while Expression args stay as data input:
translate_args_by_type([], _, [], []) :- !.
translate_args_by_type([A|As], [T|Ts], GsOut, [AV|AVs]) :-
                      ( T == 'Expression' -> AV = A, GsA = []
                                           ; translate_expr(A, GsA1, AV),
                                             ( (T == '%Undefined%' ; T == 'Atom')
                                               -> GsA = GsA1
                                                ; append(GsA1, [('get-type'(AV, T) *-> true ; 'get-metatype'(AV, T))], GsA))),
                                             translate_args_by_type(As, Ts, GsRest, AVs),
                                             append(GsA, GsRest, GsOut).

%Handle data list:
eval_data_term(X, [], X) :- (var(X); atomic(X)), !.
eval_data_term([F|As], Goals, Val) :- ( atom(F), is_fun(F) -> translate_expr([F|As], Goals, Val)
                                                         ; eval_data_list([F|As], Goals, Val) ).

%Handle data list entry:
eval_data_list([], [], []).
eval_data_list([E|Es], Goals, [V|Vs]) :-
    ( nonvar(E), E = [_|_] -> eval_data_term(E, G1, V) ; V = E, G1 = [] ),
    eval_data_list(Es, G2, Vs),
    ( G1 == [] -> Goals = G2 ; append(G1, G2, Goals) ).


%Convert let* to recusrive let:
letstar_to_rec_let([[Pat,Val]],Body,[let,Pat,Val,Body]).
letstar_to_rec_let([[Pat,Val]|Rest],Body,[let,Pat,Val,Out]) :- letstar_to_rec_let(Rest,Body,Out).

%Patterns: variables, atoms, numbers, lists:
translate_pattern(X, X) :- var(X), !.
translate_pattern(X, X) :- atomic(X), !.
translate_pattern([H|T], [P|Ps]) :- !, translate_pattern(H, P),
                                       translate_pattern(T, Ps).

% Constructs the goal for a single branch of an if-then-else/case.
build_branch(true, Val, Out, (Out = Val)) :- !.
build_branch(Con, Val, Out, Goal) :- var(Val) -> Val = Out, Goal = Con
                                               ; Goal = (Val = Out, Con).

%Translate case expression recursively into nested if:
translate_case([[K,VExpr]|Rs], Kv, Out, Goal, KGo) :- translate_expr_to_conj(VExpr, ConV, VOut),
                                                      constrain_args(K, Kc, Gc),
                                                      build_branch(ConV, VOut, Out, Then),
                                                      ( Rs == [] -> Goal = ((Kv = Kc) -> Then), KGi=[]
                                                                  ; translate_case(Rs, Kv, Out, Next, KGi),
                                                                    Goal = ((Kv = Kc) -> Then ; Next) ),
                                                      append([Gc,KGi], KGo).

%Translate arguments recursively:
translate_args([], [], []).
translate_args([X|Xs], Goals, [V|Vs]) :-
    ( (var(X) ; atomic(X)) -> V = X, G1 = []
    ; translate_expr(X, G1, V) ),
    translate_args(Xs, G2, Vs),
    ( G1 == [] -> Goals = G2 ; append(G1, G2, Goals) ).

%Build A ; B ; C ... from a list:
disj_list([G], G).
disj_list([G|Gs], (G ; R)) :- disj_list(Gs, R).

%Build one disjunct per branch: (Conj, Out = Val):
build_superpose_branches([], _, []).
build_superpose_branches([E|Es], Out, [B|Bs]) :- translate_expr_to_conj(E, Conj, Val),
                                                 build_branch(Conj, Val, Out, B),
                                                 build_superpose_branches(Es, Out, Bs).

%Build hyperpose branch as a goal list for concurrent_maplist to consume:
build_hyperpose_branches([], []).
build_hyperpose_branches([E|Es], [(Goal, Res)|Bs]) :- translate_expr_to_conj(E, Goal, Res),
                                                      build_hyperpose_branches(Es, Bs).

%Runtime hyperpose path for variable/computed list arguments.
hyperpose_runtime(Exprs, Out) :- is_list(Exprs),
                                 concurrent_and(member(Expr, Exprs), eval(Expr, Out)).

%Like membercheck but with direct equality rather than unification
memberchk_eq(V, [H|_]) :- V == H, !.
memberchk_eq(V, [_|T]) :- memberchk_eq(V, T).

%Generate readable lambda name:
next_lambda_name(Name) :- ( catch(nb_getval(lambda_counter, Prev), _, Prev = 0) ),
                          N is Prev + 1,
                          nb_setval(lambda_counter, N),
                          format(atom(Name), 'lambda_~d', [N]).
