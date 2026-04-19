:- use_module(library(dcg/basics)). %blanks/0, number/1, string_without/2

%Generate a MeTTa S-expression string from the Prolog list (stream-based, no DCG overhead):
swrite(Term, String) :- with_output_to(string(String), swrite_to_stream(Term)).

swrite_to_stream(Var)    :- var(Var), !, write('$'), term_to_atom(Var, A), write(A).
swrite_to_stream(Num)    :- number(Num), !, write(Num).
swrite_to_stream(Str)    :- string(Str), !, put_char('"'), escape_write_string(Str), put_char('"').
swrite_to_stream(Atom)   :- atom(Atom), !, write(Atom).
swrite_to_stream([])     :- !, write('()').
swrite_to_stream([H|T])  :- \+ is_list([H|T]), !,
                             put_char('('), write(cons), put_char(' '),
                             swrite_to_stream(H), put_char(' '),
                             swrite_to_stream(T), put_char(')').
swrite_to_stream([H|T])  :- !, put_char('('), swrite_seq([H|T]), put_char(')').
swrite_to_stream(Term)   :- Term =.. [F|Args],
                             put_char('('), write(F),
                             ( Args == [] -> true ; put_char(' '), swrite_seq(Args) ),
                             put_char(')').

swrite_seq([X])    :- swrite_to_stream(X).
swrite_seq([X|Xs]) :- swrite_to_stream(X), put_char(' '), swrite_seq(Xs).

escape_write_string(S) :- string_codes(S, Cs), escape_write_codes(Cs).
escape_write_codes([]).
escape_write_codes([0'"|T]) :- !, put_char('\\'), put_char('"'), escape_write_codes(T).
escape_write_codes([C|T])  :- put_code(C), escape_write_codes(T).

%Read S string or atom, extract codes, and apply DCG (parsing):
sread(S, T) :- ( atom_string(A, S),
                 atom_codes(A, Cs),
                 phrase(sexpr(T, [], _), Cs)
               -> true ; format(atom(Msg), 'Parse error in form: ~w', [S]), throw(error(syntax_error(Msg), none)) ).

%An S-Expression is a parentheses-nesting of S-Expressions that are either numbers, variables, sttrings, or atoms:
sexpr(S,E,E)  --> blanks, string_lit(S), blanks, !.
sexpr(T,E0,E) --> blanks, "(", blanks, seq(T,E0,E), blanks, ")", blanks, !.
sexpr(N,E,E)  --> blanks, number(N), ( lookahead_any(" ()\t\n\r") ; \+ [_] ), blanks, !.
sexpr(V,E0,E) --> blanks, var_symbol(V,E0,E), blanks, !.
sexpr(A,E,E)  --> blanks, atom_symbol(A), blanks.

%Helper for strange atoms that aren't numbers, e.g. 1_2_3:
lookahead_any(Terms, S, E) :- string_codes(Terms,SC), S = [Head | _], member(Head,SC), !, S = E.

%Recursive processing of S-Expressions within S-Expressions:
seq([X|Xs],E0,E2) --> sexpr(X,E0,E1), blanks, seq(Xs,E1,E2).
seq([],E,E)       --> [].

%Variables start with $, and keep track of them: re-using exising Prolog variables for variables of same name:
var_symbol(V,E0,E) --> "$", token(Cs), { atom_chars(N, Cs), ( N == '_' -> V = _, E = E0 ; memberchk(N-V0, E0) -> V = V0, E = E0 ; V = _, E = [N-V|E0] ) }.

%Atoms are derived from tokens:
atom_symbol(A) --> token(Cs), { string_codes("\"", [Q]), ( Cs = [Q|_] -> append([Q|Body], [Q], Cs), %"str" as string
                                                                         string_codes(A, Body)
                                                                       ; atom_codes(R, Cs),         %others are atoms
                                                                         ( R = 'True' -> A = true
                                                                                       ; R = 'False'
                                                                                         -> A = false
                                                                                          ; A = R ))}.

%A token is a non-empty string without whitespace:
token(Cs) --> string_without(" \t\r\n()", Cs), { Cs \= [] }.

%Just string literal handling from here-on:
string_lit(S) --> "\"", string_chars(Cs), "\"", { string_codes(S, Cs) }.
string_chars([]) --> [].
string_chars([C|Cs]) --> [C], { C =\= 0'", C =\= 0'\\ }, !, string_chars(Cs).
string_chars([C|Cs]) --> "\\", [X], { (X=0'n->C=10; X=0't->C=9; X=0'r->C=13; C=X) }, string_chars(Cs).
