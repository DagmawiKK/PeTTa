%%% error.pl — Rust-style error reporting hooks for PeTTa.
%%% Load this file to activate error diagnostics to stderr.

:- module(error_reporting, [warn_undefined/2]).
:- use_module(extension_pts).

%--- Allow error_reporting module to contribute clauses to extension_pts multifile hooks ---

:- multifile extension_pts:on_undefined_function_hook/3.
:- multifile extension_pts:on_type_mismatch_hook/4.
:- multifile extension_pts:on_arity_error_hook/4.
:- multifile extension_pts:on_arithmetic_error_hook/4.
:- multifile extension_pts:on_unbound_variable_hook/2.
:- multifile extension_pts:on_space_error_hook/3.
:- multifile extension_pts:on_parse_error_hook/3.
:- multifile extension_pts:on_runtime_error_hook/3.

%--- Location context helpers ---

% Read current file and line from globals (initialized by filereader)
petta_location(File, Line) :-
    catch(nb_getval(petta_current_file, File), _, File = '<unknown>'),
    catch(nb_getval(petta_current_line, Line), _, Line = 0).

% Format and emit an error message to stderr in Rust style
% ANSI codes: \e[1;31m = bold red, \e[0;36m = cyan, \e[0m = reset
emit_error(TypeCode, MsgAtom) :-
    petta_location(File, Line),
    format(user_error,
           "\e[1;31merror[~w]\e[0m: ~w~n\e[0;36m  --> ~w:~w\e[0m~n",
           [TypeCode, MsgAtom, File, Line]).

% Safe term-to-string conversion (with fallback)
safe_term_str(Term, Str) :-
    ( catch(swrite(Term, Str), _, fail) -> true
    ; term_to_atom(Term, Str) ).

% Special atoms that shouldn't be flagged as undefined
is_builtin_or_special(true).
is_builtin_or_special(false).
is_builtin_or_special([]).
is_builtin_or_special(fail).

%--- 1. Undefined Function Hook ---
% Called when a function head is an unregistered atom
% Skips special/builtin atoms that shouldn't be flagged
% In warn mode: log warning but return unevaluated list
% In error mode: log error and return Error term
extension_pts:on_undefined_function_hook(Fun, Args, Out) :-
    catch(nb_getval(petta_warn_undefined, WarnMode), _, WarnMode = error),
    % false = silent (fail here so extension_pts default returns data)
    WarnMode \= false,
    % Skip special atoms (true, false, [], fail, etc.)
    ( is_builtin_or_special(Fun) -> Out = [Fun|Args]
    ; safe_term_str(Fun, FunStr),
      length(Args, N),
      format(atom(Msg), "'~w' is not defined (called with ~w argument(s))", [FunStr, N]),
      ( WarnMode = true
        -> petta_location(File, Line),
           format(user_error, "warning[undefined-function]: ~w~n\e[0;36m  --> ~w:~w\e[0m~n",
                  [Msg, File, Line]),
           Out = [Fun|Args]
        ; emit_error('undefined-function', Msg),
          Out = ['Error', 'undefined-function', Msg] )
    ).

%--- 2. Type Mismatch Hook ---
% Called when a value doesn't match the expected type at a typecheck point
extension_pts:on_type_mismatch_hook(Expected, Actual, Context, Out) :-
    safe_term_str(Actual, ActStr),
    safe_term_str(Context, CtxStr),
    format(atom(Msg), "expected type '~w', got '~w' in ~w", [Expected, ActStr, CtxStr]),
    emit_error('type-error', Msg),
    Out = ['Error', 'type-error', Msg].

%--- 3. Arity Error Hook ---
% Called when actual argument count doesn't match expected arity
% Got is the list of actual arguments
extension_pts:on_arity_error_hook(Fun, Expected, Got, Out) :-
    length(Got, GotN),
    safe_term_str(Fun, FunStr),
    format(atom(Msg), "'~w' expects ~w argument(s), got ~w", [FunStr, Expected, GotN]),
    emit_error('arity-error', Msg),
    Out = ['Error', 'arity-error', Msg].

%--- 4. Arithmetic Error Hook ---
% Called when is/2 throws a type_error or instantiation_error
% PrologError is the error/2 term thrown by is/2
extension_pts:on_arithmetic_error_hook(PrologError, Op, Args, Out) :-
    safe_term_str(Op, OpStr),
    safe_term_str(Args, ArgsStr),
    ( PrologError = error(type_error(evaluable, What), _)
      -> format(atom(Msg), "arithmetic type error in '~w ~w': '~w' is not a number",
                [OpStr, ArgsStr, What])
    ; PrologError = error(instantiation_error, _)
      -> format(atom(Msg), "arithmetic error in '~w ~w': uninstantiated argument",
                [OpStr, ArgsStr])
    ; safe_term_str(PrologError, ErrStr),
      format(atom(Msg), "arithmetic error in '~w ~w': ~w", [OpStr, ArgsStr, ErrStr])
    ),
    emit_error('arithmetic-error', Msg),
    Out = ['Error', 'arithmetic-error', Msg].

%--- 5. Unbound Variable Hook ---
% Called when a variable is used in a context that requires a value
extension_pts:on_unbound_variable_hook(Context, Out) :-
    safe_term_str(Context, CtxStr),
    format(atom(Msg), "unbound variable used in function position in: ~w", [CtxStr]),
    emit_error('unbound-variable', Msg),
    Out = ['Error', 'unbound-variable', Msg].

%--- 6. Space Error Hook ---
% Called when a space operation (match/add-atom/remove-atom) throws a genuine exception
% Note: still fails after logging, so space match stays backtracking-only
extension_pts:on_space_error_hook(Space, Pattern, _Out) :-
    safe_term_str(Pattern, PatStr),
    format(atom(Msg), "space operation failed in '~w' on pattern: ~w", [Space, PatStr]),
    emit_error('space-error', Msg),
    fail.

%--- 7. Parse Error Hook ---
% Called when the parser encounters syntax errors (malformed S-expression, unbalanced parens, etc.)
% Parse errors are unrecoverable — we log the diagnostic then re-throw to halt loading
extension_pts:on_parse_error_hook(Msg, _Location, _Out) :-
    emit_error('parse-error', Msg),
    throw(error(syntax_error(Msg), none)).

%--- 8. Runtime Error Hook (Catch-all) ---
% Called for generic exceptions not covered by specific hooks
extension_pts:on_runtime_error_hook(Exception, Goal, Out) :-
    safe_term_str(Goal, GoalStr),
    safe_term_str(Exception, ExStr),
    format(atom(Msg), "runtime exception in '~w': ~w", [GoalStr, ExStr]),
    emit_error('runtime-error', Msg),
    Out = ['Error', 'runtime-error', Msg].

%--- MeTTa-callable functions for error configuration ---

% Enable or disable undefined function warnings: !(warn_undefined true/false)
% Follows MeTTa convention: last arg is the return value
warn_undefined(true,  true) :- nb_setval(petta_warn_undefined, true).
warn_undefined(false, true) :- nb_setval(petta_warn_undefined, false).

% After all files load: register warn_undefined as callable and set default to error mode
:- initialization(( register_fun(warn_undefined),
                    assertz(arity(warn_undefined, 2)),
                    nb_setval(petta_warn_undefined, error) ), program).
