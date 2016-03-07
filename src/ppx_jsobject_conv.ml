(* For implicit optional argument elimination. Annoying with Ast_helper. *)
[@@@ocaml.warning "-48"]

open StdLabels

open Ppx_core.Std
open Asttypes
open Parsetree
open Ast_builder.Default
module Type_conv = Ppx_type_conv.Std.Type_conv

let ( --> ) lhs rhs = case ~guard:None ~lhs ~rhs

let name_of_td td = match td.ptype_name.txt with
  | "t" -> "jsobject_of"
  | tn  -> "jsobject_of_" ^ tn

let wrap_runtime decls =
    [%expr let open! Ppx_deriving_jsobject_runtime in [%e decls]]

(* Courtesy of ppx_sexp_conv *)
module Fun_or_match = struct
  type t =
    | Fun   of expression
    | Match of case list

  let expr ~loc t =
    match t with
    | Fun f       -> f
    | Match cases -> pexp_function ~loc cases

  let unroll ~loc e t =
    match t with
    | Fun f       -> eapply ~loc f [e]
    | Match cases -> pexp_match ~loc e cases

  let map_tmp_vars ~loc ts =
    let vars = List.mapi ts ~f:(fun i _ -> "v" ^ string_of_int i) in
    let bindings =
      List.map2 vars ts ~f:(fun var t ->
        let expr = unroll ~loc (evar ~loc var) t in
        value_binding ~loc ~pat:(pvar ~loc var) ~expr)
    in
    (bindings,
     List.map vars ~f:(pvar ~loc),
     List.map vars ~f:(evar ~loc))
end

let jsobject_type_is_recursive =
  types_are_recursive ~short_circuit:(fun typ -> None)

let really_recursive rec_flag tds =
  match rec_flag with
  | Recursive    -> if jsobject_type_is_recursive tds then Recursive else Nonrecursive
  | Nonrecursive -> Nonrecursive

let constrained_function_binding = fun
  (* placing a suitably polymorphic or rigid type constraint on the pattern or body *)
  (loc:Location.t) (td:type_declaration) (typ:core_type) ~(tps:string list)
  ~(func_name:string) (body:expression)
->
  let pat = pvar ~loc func_name in
  value_binding ~loc ~pat ~expr:body

module Jsobject_of_expander = struct
  let mk_type td =
    combinator_type_of_type_declaration
      td ~f:(fun ~loc ty ->
        [%type: [%t ty] -> Js.Unsafe.any])

  let jsobject_of_type_id (id : Longident.t Located.t) =
    let txt : Longident.t =
      match id.txt with
      | Longident.Lident   s  -> Longident.Lident  ("jsobject_of_" ^ s)
      | Longident.Ldot (p, s) -> Longident.Ldot (p, "jsobject_of_" ^ s)
      | Longident.Lapply _    -> failwith "sexp_of_type_id"
    in
    pexp_ident ~loc:id.loc { id with txt }

  let rec jsobject_of_type (typ: core_type) : Fun_or_match.t =
    let loc = typ.ptyp_loc in
    match typ with
    | { ptyp_desc = Ptyp_constr (cid, args); _ } ->
       let init = jsobject_of_type_id cid in
       Fun_or_match.Fun (List.fold_right
              args
              ~init
              ~f:(fun tp2 exp1  ->
                let exp2 = Fun_or_match.expr ~loc (jsobject_of_type tp2) in
                [%expr [%e exp1] [%e exp2]]))
    | { ptyp_desc = Ptyp_tuple tp; _} ->
       Fun_or_match.Match [jsobject_of_tuple (loc, tp)]
    | { ptyp_desc = Ptyp_variant (row_fields, _, _); _ } ->
       jsobject_of_variant (loc, row_fields)
    | _ -> Location.raise_errorf ~loc "Ttutututu"
  (* Conversion of tuples *)
  and jsobject_of_tuple (loc, tps) =
    let fps = List.map ~f:(fun tp -> jsobject_of_type tp) tps in
    let bindings, pvars, evars = Fun_or_match.map_tmp_vars ~loc fps in
    let in_expr = [%expr
                      to_js_array
                      [%e elist ~loc evars] ] in
    let expr = pexp_let ~loc Nonrecursive bindings in_expr in
    ppat_tuple ~loc pvars --> expr
  (* Conversion of variant types *)
  and jsobject_of_variant (loc, row_fields) =
    let item = function
      | Rtag (cnstr, _, true, []) ->
         ppat_variant ~loc cnstr None -->
           [%expr to_js_array [(jsobject_of_string [%e estring ~loc cnstr])]]
      | Rtag (cnstr, _, false, [tp]) ->
        let cnstr_expr = [%expr jsobject_of_string [%e estring ~loc cnstr] ] in
        let var, patt = evar ~loc "v0", pvar ~loc "v0" in
        let cnstr_arg = Fun_or_match.unroll ~loc var (jsobject_of_type tp) in
        let expr = [%expr to_js_array [%e elist ~loc [cnstr_expr; cnstr_arg]]] in
        ppat_variant ~loc cnstr (Some patt) --> expr
      | _ ->
         Location.raise_errorf ~loc "ppx_jsobject_conv: unsupported jsobject_of_variant"
    in Fun_or_match.Match (List.map ~f:item row_fields)

  (* Conversion of sum types *)
  let branch_sum tvars cds =
    List.map cds ~f:(fun cd ->
      let loc = cd.pcd_loc in
      let cnstr = cd.pcd_name in
      let lid = Located.map lident cnstr in
      let str = estring ~loc cnstr.txt in
      match cd.pcd_args with
      | [] ->
         ppat_construct ~loc lid None -->
           [%expr to_js_array [jsobject_of_string [%e str]]]
      | args ->
         let jsobject_of_args = List.map ~f:jsobject_of_type args in
         let cnstr_expr = [%expr (jsobject_of_string [%e str])] in
         let bindings, patts, vars = Fun_or_match.map_tmp_vars ~loc jsobject_of_args in
         let patt =
           match patts with
           | [patt] -> patt
           | _ -> ppat_tuple ~loc patts
         in
         ppat_construct ~loc lid (Some patt) -->
           pexp_let ~loc
                    Nonrecursive
                    bindings
                    [%expr to_js_array
                           [%e elist ~loc (cnstr_expr :: vars)]])
  let jsobject_of_sum tps cds = Fun_or_match.Match (branch_sum tps cds)

  (* Conversion of record types *)
  let mk_rec_patt loc patt name =
    let p =
      Location.mkloc (Longident.Lident name) loc ,
      pvar ~loc ("v_" ^ name)
    in
    patt @ [p]

  let jsobject_of_record (loc,fields) =
    let coll (patts, exprs) = function
      | {pld_name = {txt=name; loc}; pld_type = tp; _ } ->
          let patts = mk_rec_patt loc patts name in
          let vname = evar ~loc ("v_" ^ name) in
          let fname = estring ~loc name in
          let cnv_expr = Fun_or_match.unroll ~loc vname (jsobject_of_type tp) in
          let expr =
            [%expr
                ([%e fname], [%e cnv_expr])]
          in
          patts, expr::exprs
    in
    let patts, exprs =
      List.fold_left ~f:coll ~init:([], []) fields
    in
    let expr = Ast_helper.Exp.array ~loc (List.rev exprs) in
    Fun_or_match.Match [
        ppat_record ~loc patts Closed -->
          [%expr make_jsobject [%e expr]]
      ]

  let jsobject_of_td td =
    let tps = List.map td.ptype_params ~f:(fun tp -> (get_type_param_name tp).txt) in
    let {ptype_name = {txt = type_name; loc = _}; ptype_loc = loc; _} = td in
    let body' =
      match td.ptype_kind with
      | Ptype_abstract -> begin
          match td.ptype_manifest with
          | Some ty -> jsobject_of_type ty
          | None -> Location.raise_errorf ~loc "ppx_jsobject_conv: fully abstract types are not supported"
        end
      | Ptype_variant cds -> jsobject_of_sum tps cds
      | Ptype_open -> Location.raise_errorf ~loc "ppx_jsobject_conv: open types are not supported"
      | Ptype_record fields -> jsobject_of_record (loc, fields)
    in
    let body = match body' with
      | Fun_or_match.Fun fun_expr -> wrap_runtime [%expr fun v -> [%e fun_expr] v ]
      | Fun_or_match.Match matchings -> wrap_runtime @@ pexp_function ~loc matchings
    in
    let typ = mk_type td in
    let func_name = name_of_td td in
    let body =
      let patts = List.map tps ~f:(fun id -> pvar ~loc ("_of_" ^ id)) in
      eabstract ~loc patts body
    in
    [constrained_function_binding loc td typ ~tps ~func_name body]


  let str_type_decl ~loc ~path:_ (rec_flag, tds) =
    let rec_flag = really_recursive rec_flag tds in
    let bindings = List.map tds ~f:jsobject_of_td |> List.concat in
    [pstr_value ~loc rec_flag bindings]

  let sig_type_decl ~loc:_ ~path:_ (_rf, tds) =
    List.map tds
             ~f:(fun td ->
               let jsobject_of = mk_type td in
               let name = name_of_td td in
               let loc = td.ptype_loc in
               psig_value ~loc (value_description
                                  ~loc
                                  ~name:{ td.ptype_name with txt = name }
                                  ~type_:jsobject_of ~prim:[]))
  let core_type ty =
    (* let loc = ty.ptyp_loc in *)
    [%expr fun a b c -> 42]

end

module Jsobject_of = struct
  let str_type_decl =
    Type_conv.Generator.make_noarg Jsobject_of_expander.str_type_decl
      ~attributes:[]
  ;;

  let sig_type_decl =
    Type_conv.Generator.make_noarg Jsobject_of_expander.sig_type_decl
  ;;

  let extension ~loc:_ ~path:_ ctyp = Jsobject_of_expander.core_type ctyp

  let deriver =
    Type_conv.add "jsobject_of"
      ~str_type_decl
      ~sig_type_decl
      ~extension
  ;;
end

(* module Of_jsobject_expander = struct *)
(*   end *)

(* module Of_jsobject = struct *)
(*   let str_type_decl = *)
(*     Type_conv.Generator.make_noarg (Of_jsobject_expander.str_type_decl ~poly:true) *)
(*       ~attributes:[ ] *)
(*   ;; *)

(*   let sig_type_decl = *)
(*     Type_conv.Generator.make_noarg (Of_jsobject_expander.sig_type_decl ~poly:true) *)
(*   ;; *)

(*   let extension ~loc:_ ~path:_ ctyp = Of_jsobject_expander.core_type ctyp *)

(*   let deriver = *)
(*     Type_conv.add "of_jsobject" *)
(*       ~str_type_decl *)
(*       ~sig_type_decl *)
(*       ~extension *)
(*   ;; *)
(* end *)


let () =
  Type_conv.add "jsobject"
                        (* Jsobject_of.deriver *)
                      (* ; *)
                        (* Of_jsobject.deriver *)
                      (* ] *)
                ~str_type_decl:Jsobject_of.str_type_decl
                ~sig_type_decl:Jsobject_of.sig_type_decl
                ~extension:Jsobject_of.extension
    (* ~sig_exception:[Jsobject_of.deriver] *)
  |> Type_conv.ignore;;
