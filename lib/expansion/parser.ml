open Ppxlib
open Util

let try_with_fail_in ~loc var_pat fn_ident cont_expr =
  [%expr let [%p var_pat] = try [%e fn_ident] ppx____parser____stream____ with Stream.Failure -> [%e raise_err_exn ~loc] in [%e cont_expr]]

let expand_list_elem ~loc cont_expr = function
  | {ppat_desc = Ppat_alias ({ppat_desc = Ppat_var ({txt = call; _}); ppat_loc = call_loc; _}, as_label); ppat_loc = as_loc; _} -> 
    let var_pat = Ast_builder.Default.ppat_var ~loc:as_loc as_label in
    let fn_ident = Ast_builder.Default.pexp_ident ~loc:call_loc ({txt = Lident call; loc}) in 
    try_with_fail_in ~loc var_pat fn_ident cont_expr
  | {ppat_desc = Ppat_var ({txt = call; _}); ppat_loc = call_loc; _} ->
    let var_pat = [%pat? _] in
    let fn_ident = Ast_builder.Default.pexp_ident ~loc:call_loc ({txt = Lident call; loc}) in
    try_with_fail_in ~loc var_pat fn_ident cont_expr
  | {ppat_desc = Ppat_extension ({txt = "let" | "l"; _}, payload); ppat_loc; _ } ->
    let e, pat = Let.expand_let_payload_tl ~loc:ppat_loc payload in
    [%expr let [%p pat] = [%e e] in [%e cont_expr]]
  | pat ->
    [%expr match [%e peek ~loc] with [%p some_pat ~loc pat] -> [%e junk ~loc cont_expr] | _ -> [%e raise_err_exn ~loc]]

let rec expand_list_seq_tl ~loc result_expr = function
  | [%pat? []] ->
    result_expr
  | [%pat? [%p? hd] :: [%p? tl]] ->
    let cont_expr = expand_list_seq_tl ~loc result_expr tl in
    expand_list_elem ~loc:hd.ppat_loc cont_expr hd
  | _ ->
    Err.err_expr_node ~loc "Expected a list of patterns."

let expand_list_seq ~loc {pc_lhs; pc_guard; pc_rhs} to_match_expr other_cases =
  let prepend_to_cases case =
    match other_cases with
    | [] -> case :: {pc_lhs = [%pat? _]; pc_guard = None; pc_rhs = raise_fail_exn ~loc} :: []
    | _ -> case :: other_cases
  in
  let bind_var_w_call pat on_match_expr pc_guard =
    let pat = some_pat ~loc:pat.ppat_loc pat in
    let on_no_match_expr = 
      match other_cases with
      | [] -> [%expr raise Stream.Failure]
      | {pc_lhs = [%pat? _]; pc_guard = None; pc_rhs} :: [] -> pc_rhs
      | _ -> Ast_builder.Default.pexp_match ~loc to_match_expr other_cases 
    in
    let match_case = {pc_lhs = pat; pc_guard; pc_rhs = on_match_expr} in
    let no_match_case = {pc_lhs = [%pat? _]; pc_guard = None; pc_rhs = on_no_match_expr} in
    match_case :: no_match_case :: []
  in
  match pc_lhs with
  | [%pat? []] ->
    let pat = [%pat? _] in
    let case = {pc_lhs = pat; pc_guard; pc_rhs} in
    let cases = 
      match pc_guard with
      | None -> case :: []
      | _ -> prepend_to_cases {pc_lhs = pat; pc_guard; pc_rhs} 
    in
    to_match_expr, cases
  | [%pat? [%p? hd] :: [%p? tl]] ->
    let on_match_expr = expand_list_seq_tl ~loc pc_rhs tl in
    begin match hd with
    | {ppat_desc = Ppat_extension ({txt = "let" | "l"; _}, payload); ppat_loc; _ } ->
      let to_match_expr, pat = Let.expand_let_payload_hd ~loc:ppat_loc payload in
      let cases = bind_var_w_call pat on_match_expr pc_guard in
      to_match_expr, cases
    | {ppat_desc = Ppat_alias ({ppat_desc = Ppat_var ({txt = call; _}); ppat_loc = call_loc; _}, as_label); ppat_loc = as_loc; _} -> 
      let var_pat = Ast_builder.Default.ppat_var ~loc:as_loc as_label in
      let fn_ident = Ast_builder.Default.pexp_ident ~loc:call_loc ({txt = Lident call; loc}) in 
      let to_match_expr = [%expr try Some ([%e fn_ident] ppx____parser____stream____) with Stream.Failure -> None] in
      let cases = bind_var_w_call var_pat on_match_expr pc_guard in
      to_match_expr, cases
    | pat ->
      let pat = some_pat ~loc:pat.ppat_loc pat in
      let on_match_expr = junk ~loc on_match_expr in
      let cases = prepend_to_cases {pc_lhs = pat; pc_guard; pc_rhs = on_match_expr} in
      to_match_expr, cases
    end
  | _ -> 
    Err.err_expr_node ~loc:pc_lhs.ppat_loc "Expected a case where the left-hand side is a list of patterns.", other_cases

let expand_function_cases ~loc cases =
  let rec iter cases =
    match cases with
    | [] ->
      peek ~loc, cases
    | case :: cases_rest ->
      let to_match_expr, cases = iter cases_rest in
      expand_list_seq ~loc:case.pc_lhs.ppat_loc case to_match_expr cases
  in
  iter cases

let expand_function ~loc cases =
  let to_match_expr, cases = expand_function_cases ~loc cases in
  let match_expr = Ast_builder.Default.pexp_match ~loc to_match_expr cases in
  [%expr function ppx____parser____stream____ -> [%e match_expr]]

let expand_function_from_ctxt ~ctxt cases = 
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  expand_function ~loc cases
