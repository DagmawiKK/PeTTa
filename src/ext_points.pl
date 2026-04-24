:- multifile metta_try_dispatch_call/4.
:- multifile metta_on_function_changed/1.
:- multifile metta_on_function_removed/1.
:- multifile metta_on_space_atom_added/2.
:- multifile metta_on_space_atom_removed/2.
:- multifile metta_constrain_arg/3.
:- multifile metta_translate_literal/3.
:- multifile metta_translate_head/5.
:- multifile metta_translate_typed_arg/4.
:- multifile metta_get_type_candidate/2.
:- multifile metta_present_term/2.

metta_try_dispatch_call(_, _, _, _) :- fail.
metta_on_function_changed(_).
metta_on_function_removed(_).
metta_on_space_atom_added(_, _).
metta_on_space_atom_removed(_, _).
metta_constrain_arg(_, _, _) :- fail.
metta_translate_literal(_, _, _) :- fail.
metta_translate_head(_, _, _, _, _) :- fail.
metta_translate_typed_arg(_, _, _, _) :- fail.
metta_get_type_candidate(_, _) :- fail.
metta_present_term(_, _) :- fail.
