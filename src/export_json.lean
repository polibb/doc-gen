/-
Copyright (c) 2019 Robert Y. Lewis. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Robert Y. Lewis
-/

import tactic.core system.io data.string.defs tactic.interactive data.list.sort
import all

/-!
Used to generate a json file for html docs.

The json file is a list of maps, where each map has the structure
{ name: string,
  args : list string,
  type: string,
  doc_string: string,
  filename: string,
  line: int,
  attributes: list string,
  equations: list string,
  kind: string,
  structure_fields: list (list string),
  constructors: list (list string) }

The lists in structure_fields and constructors are assumed to contain two strings each.

Include this file somewhere in mathlib, e.g. in the `scripts` directory. Make sure mathlib is
precompiled, with `all.lean` generated by `mk_all.sh`.

Usage: `lean --run export_json.lean` creates `json_export.txt` in the current directory.
-/

open tactic io io.fs native

set_option pp.generalized_field_notation true

meta inductive efmt
| compose (a b : efmt)
| of_format (f : format)
| nest (f : efmt)

namespace efmt

meta instance : has_append efmt := ⟨compose⟩
meta instance : has_coe format efmt := ⟨of_format⟩

meta def to_json : efmt → format
| (compose a b) := format!"[\"c\",{a.to_json},{b.to_json}]"
| (of_format f) := repr f.to_string
| (nest f) := format!"[\"n\",{f.to_json}]"

meta def compose' : efmt → efmt → efmt
| (of_format a) (of_format b) := of_format (a ++ b)
| (of_format a) (compose (of_format b) c) := of_format (a ++ b) ++ c
| (compose a (of_format b)) (of_format c) := a ++ of_format (b ++ c)
| a b := compose a b

meta def of_eformat : eformat → efmt
| (tagged_format.group g) := nest (of_eformat g)
| (tagged_format.nest i g) := nest (of_eformat g)
| (tagged_format.tag _ g) := of_eformat g
| (tagged_format.highlight _ g) := of_eformat g
| (tagged_format.compose a b) := compose' (of_eformat a) (of_eformat b)
| (tagged_format.of_format f) := of_format f

meta def pp (e : expr) : tactic efmt :=
of_eformat <$> pp_tagged e

end efmt

/-- The information collected from each declaration -/
meta structure decl_info :=
(name : name)
(is_meta : bool)
(args : list (bool × efmt)) -- tt means implicit
(type : efmt)
(doc_string : option string)
(filename : string)
(line : ℕ)
(attributes : list string) -- not all attributes, we have a hardcoded list to check
(equations : list efmt)
(kind : string) -- def, thm, cnst, ax
(structure_fields : list (string × efmt)) -- name and type of fields of a constructor
(constructors : list (string × efmt)) -- name and type of constructors of an inductive type

structure module_doc_info :=
(filename : string)
(line : ℕ)
(content : string)

section
set_option old_structure_cmd true

structure ext_tactic_doc_entry extends tactic_doc_entry :=
(imported : string)

meta def escape_name : name → string :=
repr ∘ to_string

meta def ext_tactic_doc_entry.to_string : ext_tactic_doc_entry → string
| ⟨name, category, decl_names, tags, description, _, imported⟩ :=
let decl_names := decl_names.map escape_name,
    tags := tags.map repr in
"{" ++ to_string (format!"\"name\": {repr name}, \"category\": \"{category}\", \"decl_names\":{decl_names}, \"tags\": {tags}, \"description\": {repr description}, \"import\": {repr imported}") ++ "}"
end

meta def print_arg : bool × efmt → string
| (b, s) := let bstr := if b then "true" else "false" in
"{" ++ (to_string $ format!"\"arg\":{s.to_json}, \"implicit\":{bstr}") ++ "}"

meta def decl_info.to_format : decl_info → format
| ⟨name, is_meta, args, type, doc_string, filename, line, attributes, equations, kind, structure_fields, constructors⟩ :=
let doc_string := doc_string.get_or_else "",
    is_meta := if is_meta then "true" else "false",
    args := args.map print_arg,
    attributes := attributes.map repr,
    equations := equations.map efmt.to_json,
    structure_fields := structure_fields.map (λ ⟨n, t⟩, format!"[{escape_name n}, {t.to_json}]"),
    constructors := constructors.map (λ ⟨n, t⟩, format!"[{escape_name n}, {t.to_json}]") in
"{" ++ format!"\"name\":{escape_name name}, \"is_meta\":{is_meta}, \"args\":{args}, \"type\":{type.to_json}, \"doc_string\":{repr doc_string}, "
    ++ format!"\"filename\":\"{filename}\",\"line\":{line}, \"attributes\":{attributes}, \"equations\":{equations}, "
    ++ format!" \"kind\":{repr kind}, \"structure_fields\":{structure_fields}, \"constructors\":{constructors}" ++ "}"

section

open tactic.interactive

-- tt means implicit
meta def format_binders (ns : list name) (bi : binder_info) (t : expr) : tactic (bool × efmt) := do
t' ← efmt.pp t,
let use_instance_style : bool := ns.length = 1
  ∧ "_".is_prefix_of ns.head.to_string
  ∧ bi = binder_info.inst_implicit,
let t' := if use_instance_style then t' else format_names ns ++ " : " ++ t',
let brackets : string × string := match bi with
  | binder_info.default := ("(", ")")
  | binder_info.implicit := ("{", "}")
  | binder_info.strict_implicit := ("⦃", "⦄")
  | binder_info.inst_implicit := ("[", "]")
  | binder_info.aux_decl := ("(", ")") -- TODO: is this correct?
  end,
pure $ prod.mk (bi ≠ binder_info.default : bool) $ (brackets.1 : efmt) ++ t' ++ brackets.2

meta def binder_info.is_inst_implicit : binder_info → bool
| binder_info.inst_implicit := tt
| _ := ff

meta def count_named_intros : expr → tactic ℕ
| e@(expr.pi _ bi _ _) :=
  do ([_], b) ← mk_local_pisn e 1,
     v ← count_named_intros b,
     return $ if v = 0 ∧ e.is_arrow ∧ ¬ bi.is_inst_implicit then v else v + 1
| _ := return 0

/- meta def count_named_intros : expr → ℕ
| e@(expr.pi _ _ _ b) :=
  let v := count_named_intros b in
  if v = 0 ∧ e.is_arrow then v else v + 1
| _ := 0 -/

-- tt means implicit
meta def get_args_and_type (e : expr) : tactic (list (bool × efmt) × efmt) :=
prod.fst <$> solve_aux e (
do count_named_intros e >>= intron,
   cxt ← local_context >>= tactic.interactive.compact_decl,
   cxt' ← cxt.mmap (λ t, do ft ← format_binders t.1 t.2.1 t.2.2, return (ft.1, ft.2)),
   tgt ← target >>= efmt.pp,
   return (cxt', tgt))

end

/-- The attributes we check for -/
meta def attribute_list := [`simp, `squash_cast, `move_cast, `elim_cast, `nolint, `ext, `instance, `class]

meta def attributes_of (n : name) : tactic (list string) :=
list.map to_string <$> attribute_list.mfilter (λ attr, succeeds $ has_attribute attr n)

meta def declaration.kind : declaration → string
| (declaration.defn a a_1 a_2 a_3 a_4 a_5) := "def"
| (declaration.thm a a_1 a_2 a_3) := "thm"
| (declaration.cnst a a_1 a_2 a_3) := "cnst"
| (declaration.ax a a_1 a_2) := "ax"

-- does this not exist already? I'm confused.
meta def expr.instantiate_pis : list expr → expr → expr
| (e'::es) (expr.pi n bi t e) := expr.instantiate_pis es (e.instantiate_var e')
| _        e              := e

meta def enable_links : tactic unit :=
do o ← get_options, set_options $ o.set_bool `pp.links tt

-- assumes proj_name exists
meta def get_proj_type (struct_name proj_name : name) : tactic efmt :=
do (locs, _) ← mk_const struct_name >>= infer_type >>= mk_local_pis,
   proj_tp ← mk_const proj_name >>= infer_type,
   (_, t) ← mk_local_pisn (proj_tp.instantiate_pis locs) 1,
   efmt.pp t

meta def mk_structure_fields (decl : name) (e : environment) : tactic (list (string × efmt)) :=
match e.is_structure decl, e.structure_fields_full decl with
| tt, some proj_names := proj_names.mmap $
    λ n, do tp ← get_proj_type decl n, return (to_string n, tp)
| _, _ := return []
end

-- this is used as a hack in get_constructor_type to avoid printing `Type ?`.
meta def mk_const_with_params (d : declaration) : expr :=
let lvls := d.univ_params.map level.param in
expr.const d.to_name lvls

meta def get_constructor_type (type_name constructor_name : name) : tactic efmt :=
do d ← get_decl type_name,
   (locs, _) ← infer_type (mk_const_with_params d) >>= mk_local_pis,
   env ← get_env,
   let locs := locs.take (env.inductive_num_params type_name),
   proj_tp ← mk_const constructor_name >>= infer_type,
   do t ← pis locs (proj_tp.instantiate_pis locs), --.abstract_locals (locs.map expr.local_uniq_name),
   efmt.pp t

meta def mk_constructors (decl : name) (e : environment): tactic (list (string × efmt)) :=
if (¬ e.is_inductive decl) ∨ (e.is_structure decl) then return [] else
do d ← get_decl decl, ns ← get_constructors_for (mk_const_with_params d),
   ns.mmap $ λ n, do tp ← get_constructor_type decl n, return (to_string n, tp)

meta def get_equations (decl : name) : tactic (list efmt) := do
ns ← get_eqn_lemmas_for tt decl,
ns.mmap $ λ n, do
d ← get_decl n,
(_, ty) ← mk_local_pis d.type,
efmt.pp ty

/-- extracts `decl_info` from `d`. Should return `none` instead of failing. -/
meta def process_decl (d : declaration) : tactic (option decl_info) :=
do ff ← d.in_current_file | return none,
   e ← get_env,
   let decl_name := d.to_name,
   if decl_name.is_internal ∨ d.is_auto_generated e then return none else do
   some filename ← return (e.decl_olean decl_name) | return none,
   some ⟨line, _⟩ ← return (e.decl_pos decl_name) | return none,
   doc_string ← (some <$> doc_string decl_name) <|> return none,
   (args, type) ← get_args_and_type d.type,
   attributes ← attributes_of decl_name,
   equations ← get_equations decl_name,
   structure_fields ← mk_structure_fields decl_name e,
   constructors ← mk_constructors decl_name e,
   return $ some ⟨decl_name, !d.is_trusted, args, type, doc_string, filename, line, attributes, equations, d.kind, structure_fields, constructors⟩

meta def run_on_dcl_list (e : environment) (ens : list name) (handle : handle) (is_first : bool) : io unit :=
ens.mfoldl  (λ is_first d_name, do
     d ← run_tactic (e.get d_name),
     odi ← run_tactic (enable_links >> process_decl d),
     match odi with
     | some di := do
        when (bnot is_first) (put_str_ln handle ","),
        put_str_ln handle $ to_string di.to_format,
        return ff
     | none := return is_first
     end) is_first >> return ()

meta def itersplit {α} : list α → ℕ → list (list α)
| l 0 := [l]
| l 1 := let (l1, l2) := l.split in [l1, l2]
| l (k+2) := let (l1, l2) := l.split in itersplit l1 (k+1) ++ itersplit l2 (k+1)

meta def write_module_doc_pair : pos × string → string
| (⟨line, _⟩, doc) := "{\"line\":" ++ to_string line ++ ", \"doc\" :" ++ repr doc ++ "}"

meta def write_olean_docs : tactic (list string) :=
do docs ← olean_doc_strings,
   return (docs.foldl (λ rest p, match p with
   | (none, _) := rest
   | (_, []) := rest
   | (some filename, l) :=
     let new := "\"" ++ filename ++ "\":" ++ to_string (l.map write_module_doc_pair)  in
     new::rest
   end) [])

meta def get_instances : tactic (rb_lmap string string) :=
attribute.get_instances `instance >>= list.mfoldl
  (λ map inst_nm,
   do (_, e) ← mk_const inst_nm >>= infer_type >>= mk_local_pis,
      (expr.const class_nm _) ← return e.get_app_fn,
      return $ map.insert class_nm.to_string inst_nm.to_string)
  mk_rb_map

meta def format_instance_list : tactic string :=
do map ← get_instances,
   let lst := map.to_list.map (λ ⟨n, l⟩, to_string format!"\"{n}\" : {repr l}"),
   return $ "{" ++ (string.join (lst.intersperse ",")) ++ "}"

meta def format_notes : tactic string :=
do l ← get_library_notes,
   let l := l.map $ λ ⟨l, r⟩, to_string $ format!"[{repr l}, {repr r}]",
   let l := string.join $ l.intersperse ", ",
   return $ to_string $ format!"[{l}]"

meta def name.imported_by_tactic_basic (decl_name : name) : bool :=
let env := environment.from_imported_module_name `tactic.basic in
env.contains decl_name

meta def name.imported_by_tactic_default (decl_name : name) : bool :=
let env := environment.from_imported_module_name `tactic.default in
env.contains decl_name

meta def name.imported_always (decl_name : name) : bool :=
let env := environment.from_imported_module_name `system.random in
env.contains decl_name

meta def tactic_doc_entry.add_import : tactic_doc_entry → ext_tactic_doc_entry
| ⟨name, category, [], tags, description, idf⟩ := ⟨name, category, [], tags, description, idf, ""⟩
| ⟨name, category, rel_decls@(decl_name::_), tags, description, idf⟩ :=
  let imported := if decl_name.imported_always then "always imported"
                  else if decl_name.imported_by_tactic_basic then "tactic.basic"
                  else if decl_name.imported_by_tactic_default then "tactic"
                  else "" in
  ⟨name, category, rel_decls, tags, description, idf, imported⟩

meta def format_tactic_docs : tactic string :=
do l ← list.map tactic_doc_entry.add_import <$> get_tactic_doc_entries,
   return $ to_string $ l.map ext_tactic_doc_entry.to_string

/-- Using `environment.mfold` is much cleaner. Unfortunately this led to a segfault, I think because
of a stack overflow. Converting the environment to a list of declarations and folding over that led
to "deep recursion detected". Instead, we split that list into 8 smaller lists and process them
one by one. More investigation is needed. -/
meta def export_json (filename : string) : io unit :=
do handle ← mk_file_handle filename mode.write,
   put_str_ln handle "{ \"decls\":[",
   e ← run_tactic get_env,
   let ens := environment.get_decl_names e,
   let enss := itersplit ens 4,
   enss.mfoldl (λ is_first l, do run_on_dcl_list e l handle is_first, return ff) tt,
   put_str_ln handle "],",
   ods ← run_tactic write_olean_docs,
   put_str_ln handle $ "\"mod_docs\": {" ++ string.join (ods.intersperse ",\n") ++ "},",
   notes ← run_tactic format_notes,
   put_str_ln handle $ "\"notes\": " ++ notes ++ ",",
   tactic_docs ← run_tactic format_tactic_docs,
   put_str_ln handle $ "\"tactic_docs\": " ++ tactic_docs ++ ",",
   instl ← run_tactic format_instance_list,
   put_str_ln handle $ "\"instances\": " ++ instl ++ "}",
   close handle

meta def main : io unit :=
export_json "json_export.txt"

