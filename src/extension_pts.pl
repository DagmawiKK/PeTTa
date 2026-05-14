%%% extension_pts.pl — Extension point declarations for PeTTa error reporting.
%%% Loading this file alone is a no-op (all defaults preserve current behavior).
%%% Load error.pl to activate Rust-style error diagnostics.

:- module(extension_pts, [
    on_undefined_function/3,
    on_type_mismatch/4,
    on_arity_error/4,
    on_arithmetic_error/4,
    on_unbound_variable/2,
    on_space_error/3,
    on_parse_error/3,
    on_runtime_error/3
]).

%--- Hook declarations (multifile predicates so error.pl can contribute clauses) ---

:- multifile on_undefined_function_hook/3.
:- multifile on_type_mismatch_hook/4.
:- multifile on_arity_error_hook/4.
:- multifile on_arithmetic_error_hook/4.
:- multifile on_unbound_variable_hook/2.
:- multifile on_space_error_hook/3.
:- multifile on_parse_error_hook/3.
:- multifile on_runtime_error_hook/3.

%--- Location context globals (initialized at load time) ---

:- nb_setval(petta_current_file, '<unknown>').
:- nb_setval(petta_current_line, 0).
:- nb_setval(petta_warn_undefined, false).

%--- Dispatch predicates with safe defaults ---

% DEFAULT: leave as unevaluated list (matches current reduce/2 Case 3 behavior)
on_undefined_function(Fun, Args, Out) :-
    ( on_undefined_function_hook(Fun, Args, Out) -> true
    ; Out = [Fun|Args] ).

% DEFAULT: no-op, return actual value unchanged (no type enforcement currently)
on_type_mismatch(Expected, Actual, Context, Out) :-
    ( on_type_mismatch_hook(Expected, Actual, Context, Out) -> true
    ; Out = Actual ).

% DEFAULT: return partial closure (matches current build_call_or_partial fallback)
on_arity_error(Fun, Expected, Got, Out) :-
    ( on_arity_error_hook(Fun, Expected, Got, Out) -> true
    ; Out = partial(Fun, Got) ).

% DEFAULT: re-throw the Prolog error (current behavior: is/2 throws unguarded)
on_arithmetic_error(PrologError, Op, Args, Out) :-
    ( on_arithmetic_error_hook(PrologError, Op, Args, Out) -> true
    ; throw(PrologError) ).

% DEFAULT: fail (leave variable unevaluated, reduce/2 Case 3 path)
on_unbound_variable(Context, Out) :-
    ( on_unbound_variable_hook(Context, Out) -> true
    ; Out = [] ).

% DEFAULT: fail (matches current catch(Term, _, fail) in spaces.pl)
on_space_error(Space, Pattern, Out) :-
    ( on_space_error_hook(Space, Pattern, Out) -> true
    ; fail ).

% DEFAULT: throw the same error (current behavior: filereader/parser throw directly)
on_parse_error(Msg, Location, Out) :-
    ( on_parse_error_hook(Msg, Location, Out) -> true
    ; throw(error(syntax_error(Msg), none)) ).

% DEFAULT: re-throw (current behavior: raw Prolog exceptions propagate)
on_runtime_error(Exception, Goal, Out) :-
    ( on_runtime_error_hook(Exception, Goal, Out) -> true
    ; throw(Exception) ).
