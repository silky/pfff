(* Yoann Padioleau
 *
 * Copyright (C) 2013, 2014 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

open Parser_clang
open Ast_clang
module Ast = Ast_clang
module Loc = Location_clang
module Typ = Type_clang
module E = Database_code
module G = Graph_code

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * Graph of dependencies for Clang ASTs. See graph_code.ml and
 * main_codegraph.ml for more information.
 * 
 * schema:
 *  Root -> Dir -> File (.c|.h) -> Function | Prototype
 *                              -> Global | GlobalExtern
 *                              -> Type (for Typedef)
 *                              -> Type (struct|enum|union)
 *                                 -> Field
 *                                 -> Constructor (enum)
 *       -> Dir -> SubDir -> ...
 * 
 * Note that there is no Constant here as #define are not in clang ASTs
 * as the preprocessor has been called already on the file.
 * 
 * procedure to analyze a project:
 *  $ make V=1 > make_trace.txt
 *  $ ~/pfff/pfff_test -analyze_make_trace make_trace.txt >compile_commands.json
 *  $ ~/pfff/pfff -gen_clang compile_commands.json 
 *  $ ~/pfff/pfff_test -uninclude_clang
 *  $ ~/pfff/codegraph -lang clang2 -build .
 * 
 * alternative when project uses cmake:
 *  $ cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 
 *  $ mv compile_commands.json old.json
 *  $ ~/pfff/pfff -sanitize_compile_commands old.json > compile_commands.json
 *  $ ~/pfff/pfff -gen_clang ...
 *  $ ...
 * 
 * related:
 *  - http://code.google.com/p/include-what-you-use/wiki/WhyIWYU
 * 
 * todo: 
 *  - Type is a bit overloaded maybe (used for struct, enum, union, typedefs)
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type env = {
  g: Graph_code.graph;
  phase: phase;
  (* now in Graph_code.gensym:  cnt: int ref; *)

  current: Graph_code.node;

  root: Common.dirname;
  c_file_readable: Common.filename;
  (* as mentionned in the .clang *)
  c_file_absolute: Common.filename;

  current_c_line: int ref;
  (* this is there in support for current_c_line, see update_line() *)
  current_c_file: Common.filename ref;

  (* for error reports *)
  clang2_file: Common.filename;
  (* line number in .clang file (not .c file, nor .clang2 file) *)
  clang_line: int;

  at_toplevel: bool;
  (* for prolog use/4 *)
  in_assign: bool;
  (* we don't need to store also the 'params' as they are marked specially
   * as ParamVar in the AST.
   *)
  locals: string list ref;
  (* static functions, globals, 'main', and local enums renaming *)
  local_rename: (string, string) Hashtbl.t;

  conf: config;
  (* less: we could also have a local_typedefs field *)
  typedefs: (string, Type_clang.type_clang) Hashtbl.t;
  dupes: (Graph_code.node, bool) Hashtbl.t;

  log: string -> unit;
  pr2_and_log: string -> unit;
}
 and phase = Defs | Uses

and config = {
  (* We normally expand references to typedefs, to normalize and simplify
   * things. Set this variable to true if instead you want to know who is
   * using a typedef.
   *)
  typedefs_dependencies: bool;
  types_dependencies: bool;
  fields_dependencies: bool;
  propagate_deps_def_to_decl: bool;
}

let unknown_location = "Unknown_Location", E.File

type kind_file = Source | Header


(*****************************************************************************)
(* Parsing *)
(*****************************************************************************)

let parse file = 
  Common.profile_code "Parse_clang.parse" (fun () -> 
   (* clang2_old: Parse_clang.parse file *)
    try 
      Common2.get_value file
    with exn ->
      failwith (spf "PB with %s (exn = %s)" file (Common.exn_to_s exn))
  )

(*****************************************************************************)
(* Adjusters *)
(*****************************************************************************)

let propagate_users_of_functions_globals_types_to_prototype_extern_typedefs g =
  let pred = G.mk_eff_use_pred g in
  g +> G.iter_nodes (fun n ->
    let n_def_opt =
      match n with
      | s, E.Prototype -> Some (s, E.Function)
      | s, E.GlobalExtern -> Some (s, E.Global)
      (* todo: actually should look at env.typedefs because it's not
       * necessaraly T_Xxxx -> S_Xxxx
       *)
      | s, E.Type when s =~ "T__\\(.*\\)$" -> 
        Some ("S__" ^(Common.matched1 s), E.Type)
      | _ -> None
    in
    n_def_opt +> Common.do_option (fun n_def ->
      let n_decl = n in
      if G.has_node n_def g 
      then begin
        (* let's create a link between the def and the decl *)
        g +> G.add_edge (n_def, n_decl) G.Use;
        (* and now the users *)
        let users = pred n_def in
        users +> List.iter (fun user ->
          g +> G.add_edge (user, n_decl) G.Use
        )
      end
    )
  )
    


(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
(* we can have different .c files using the same function name, so to avoid
 * dupes we locally rename those entities, e.g. main -> main__234.
 *)
let new_str_if_defs env s =
  if env.phase = Defs
  then begin
    let s2 = Graph_code.gensym s in
    Hashtbl.add env.local_rename s s2;
    s2
  end
  else Hashtbl.find env.local_rename s

(* anywhere you get a string from the AST you must use this function to
 * get the final "value" *)
let str env s =
  if Hashtbl.mem env.local_rename s
  then Hashtbl.find env.local_rename s
  else s

let loc_of_env env =
  env.clang2_file, env.clang_line

let error env s =
  Errors_clang.error (loc_of_env env) s

(* to get a stable and unique name, see comment in location_clang.ml *)
let str_of_angle_loc env loc =
  Location_clang.str_of_angle_loc env.clang_line loc env.clang2_file

(* The .clang2 even after -uninclude can contain reference to other files.
 * For instance all macro expanded code may refer to the original location
 * in a header file. So we need to take care when maintaining the
 * line information.
 *)
let update_current_c_file_line env (enum, l, xs) =
  let locations = 
    Loc.locations_of_paren env.clang2_file (enum, l, xs) in
  let update_line_if_same_file l =
    if !(env.current_c_file) =$= env.c_file_absolute
    then env.current_c_line := l
  in

  let rec aux = function
    | [] -> ()
    (* for range, we care about the first position, so discard second Line *)
    | [Loc.File (file, l, _col);Loc.Line _] ->
        env.current_c_file := file;
        update_line_if_same_file l
    | [Loc.Line (l, _col);Loc.Line _] ->
        update_line_if_same_file l
    | x::xs ->
        (match x with
        | Loc.File (file, l, _col) ->
            env.current_c_file := file;
            update_line_if_same_file l
        | Loc.Line (l, _col) ->
            update_line_if_same_file l
        | Loc.Col _ | Loc.Other -> ()
        );
      aux xs
  in
  aux locations

let kind_file env =
  match env.clang2_file with
  | s when s =~ ".*\\.[h]\\.clang2" -> Header
  | s when s =~ ".*\\.[cm]\\.clang2" -> Source
  | _s  ->
   (* failwith ("unknown kind of file: " ^ s) *)
    Source

(*****************************************************************************)
(* Add Node *)
(*****************************************************************************)

let add_node_and_edge_if_defs_mode env node =
  let (str, kind) = node in
  let str' =
    match kind, env.current with
    | E.Field, (s, E.Type) ->
        s ^ "." ^ str
    | _ -> str
  in
  let node = (str', kind) in

  if env.phase = Defs then
    (match () with
    (* if parent is a dupe, then don't want to attach yourself to the
     * original parent, mark this child as a dupe too.
     *)
    | _ when Hashtbl.mem env.dupes env.current ->
        Hashtbl.replace env.dupes node true
    (* already there? a dupe? *)
    | _ when G.has_node node env.g ->
      (match kind with
      | E.Function | E.Global | E.Constructor
      | E.Type | E.Field
        ->
          (match kind, str with
          | E.Type, (
              (* clang builtins *)
                "T____int128_t" | "T____uint128_t"  | "T____builtin_va_list"
              (* /usr/include dupes. 
               * todo: could look if same def body and if both duped entities
               * are in EXTERNAL/
               *)
              | "T__pid_t" | "T__intptr_t" | "T__off_t" | "T__ssize_t"
              | "T__dev_t" | "T__mode_t"
            )
              -> ()
          (* dupe typedefs are ok as long as they are equivalent, and this
           * check is done for TypedefDecl below in decl().
           *)
          | E.Type, s when s =~ "T__" -> ()
          | _ when env.clang2_file =~ ".*EXTERNAL" -> ()
          (* todo: if typedef then maybe ok if have same content!! *)
          | _ when not env.conf.typedefs_dependencies && str =~ "T__.*" -> 
              Hashtbl.replace env.dupes node true;
          | _ ->
              env.pr2_and_log (spf "DUPE entity: %s" (G.string_of_node node));
              let nodeinfo = G.nodeinfo node env.g in
              let orig_file = nodeinfo.G.pos.Parse_info.file in
              env.log (spf " orig = %s" orig_file);
              env.log (spf " dupe = %s" env.c_file_readable);
              Hashtbl.replace env.dupes node true;
          )
      (* todo: have no Use for now for those so skip errors *) 
      | E.Prototype | E.GlobalExtern -> 
        (* It's common to have multiple times the same prototype declared.
         * It can also happen that the same prototype have
         * different types (e.g. in plan9 newword() had an argument with type
         * 'Word' and another 'word'). We don't want to add to the same
         * entity dependencies to this different types so we need to mark
         * the prototype as a dupe too!
         * Anyway normally we should add the deps to the Function or Global
         * first so we should hit this code only for really external
         * entities.
         *)
         Hashtbl.replace env.dupes node true;
      | _ ->
          failwith (spf "Unhandled category: %s" (G.string_of_node node))
      )
    (* ok not a dupe, let's add it then *)
    | _ ->
      (* less: still needed to have a try? *)
      try
        let nodeinfo = { Graph_code.
          pos = { Parse_info.
            str = "";
            charpos = -1; column = -1;
            line = !(env.current_c_line); 
            file = env.c_file_readable;
          };
          props = [];
        } in
        env.g +> G.add_node node;
        env.g +> G.add_edge (env.current, node) G.Has;
        env.g +> G.add_nodeinfo node nodeinfo;
      with Not_found ->
        error env ("Not_found:" ^ str)
    );
  { env with current = node }

(*****************************************************************************)
(* Add edge *)
(*****************************************************************************)

let rec add_use_edge env (s, kind) =
  let src = env.current in
  let dst = (s, kind) in
  match () with
  | _ when Hashtbl.mem env.dupes src || Hashtbl.mem env.dupes dst ->
      (* todo: stats *)
      env.pr2_and_log (spf "skipping edge (%s -> %s), one of it is a dupe"
                         (G.string_of_node src) (G.string_of_node dst));
  (* plan9, those are special functions in kencc? *)
  | _ when s =$= "USED" || s =$= "SET" ->  ()
  | _ when not (G.has_node src env.g) ->
      error env ("SRC FAIL:" ^ G.string_of_node src);
  (* the normal case *)
  | _ when G.has_node dst env.g ->
      G.add_edge (src, dst) G.Use env.g;
      (match kind with
      | E.Global | E.Field ->
        let oldinfoopt = G.edgeinfo_opt (src, dst) G.Use env.g in
        let info = 
          match oldinfoopt with
          | Some info -> info
          | None -> { G.read = false; G.write = false }
        in
        let newinfo =
          if env.in_assign
          then { info with G.write = true }
          else { info with G.read = true }
        in
        G.add_edgeinfo (src, dst) G.Use newinfo env.g
      | _ -> ()
      );
  | _ ->
    (match kind with
    (* look for Prototype if no Function *)
    | E.Function -> add_use_edge env (s, E.Prototype)
    (* look for GlobalExtern if no Global *)
    | E.Global -> add_use_edge env (s, E.GlobalExtern)

    | _ when env.clang2_file =~ ".*EXTERNAL" -> 
        ()
    (* todo? if we use 'b' in the 'a':'b' type string, still need code below?*)
    | E.Type when s =~ "S__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
    | E.Type when s =~ "U__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
    | E.Type when s =~ "E__\\(.*\\)" ->
        add_use_edge env ("T__" ^ Common.matched1 s, E.Type)
    | _ ->
        env.pr2_and_log (spf "Lookup failure on %s (%s:%d)"
                            (G.string_of_node dst)
                            env.clang2_file
                            env.clang_line
        )
    )

      
let add_type_deps env typ =
  if env.phase = Uses && env.conf.types_dependencies then begin
    let loc = loc_of_env env in
    let toks = 
      Type_clang.tokens_of_brace_sexp env.conf.typedefs_dependencies loc typ in
    let t = Type_clang.type_of_tokens loc toks in
    let t = 
      if env.conf.typedefs_dependencies
      then t 
      else Type_clang.expand_typedefs env.typedefs t
    in
    let rec aux t = 
      match t with
      | Typ.Builtin _ -> ()
      | Typ.StructName s -> add_use_edge env ("S__"^s, E.Type)
      | Typ.UnionName s -> add_use_edge env ("U__"^s, E.Type)
      | Typ.EnumName s -> add_use_edge env ("E__"^s, E.Type)
      | Typ.Typename s ->
          if env.conf.typedefs_dependencies
          then add_use_edge env ("T__"^s, E.Type)
          else 
            if Hashtbl.mem env.typedefs s
            then 
              let t' = (Hashtbl.find env.typedefs s) in
              (* right now 'typedef enum { ... } X' results in X being
               * typedefed to ... itself
               *)
              if t' = t
              then add_use_edge env ("T__"^s, E.Type)
              (* should be done in expand_typedefs *)
              else raise Impossible
            else env.pr2_and_log ("typedef not found:" ^ s)

      (* less: use the canonical type in that case? *)
      | Typ.TypeofStuff -> ()

      (* todo? *)
      | Typ.AnonStuff -> ()
      | Typ.Other _ -> ()

      | Typ.Pointer x -> aux x
      (* todo: should analyze parameters *)
      | Typ.Function x -> aux x
    in
    aux t
  end

(*****************************************************************************)
(* Defs/Uses *)
(*****************************************************************************)
let rec extract_defs_uses env ast =

  let c_file =
    if env.clang2_file =~ "\\(.*\\).clang2"
    then Common.matched1 env.clang2_file
    else failwith "not a clang2 file?"
  in
  let c_file_readable = Common.readable ~root:env.root c_file in

  if env.phase = Defs then begin
    let dir = Common2.dirname c_file_readable in
    G.create_intermediate_directories_if_not_present env.g dir;
    let node = (c_file_readable, E.File) in
    env.g +> G.add_node node;
    env.g +> G.add_edge ((dir, E.Dir), node) G.Has;
  end;
  let env = { env with 
    current = (c_file_readable, E.File);
    current_c_line = ref 1;
    c_file_readable;
    c_file_absolute = c_file;
    current_c_file = ref c_file;
  } in
  match ast with
  | Paren (TranslationUnitDecl, _l, _loc::xs) ->
      List.iter (sexp_toplevel env) xs
  | _ -> 
      error env "not a TranslationDecl"
  

and sexp_toplevel env x =
  match x with
  | Paren (enum, l, xs) ->
      let env = { env with clang_line = l } in
      update_current_c_file_line env (enum, l, xs);

      (* dispatcher *)
      (match enum with
      | FunctionDecl | VarDecl
      | TypedefDecl | RecordDecl | EnumDecl 
      | FieldDecl | EnumConstantDecl
        -> decl env (enum, l, xs)
      | LinkageSpecDecl ->
          (match xs with
          | _loc::T (TUpperIdent "C")::xs ->
              xs +> List.iter (sexp_toplevel env)
          | _ -> error env "weird LinkageSpecDecl"
          )

      | CallExpr | DeclRefExpr | MemberExpr | UnaryExprOrTypeTraitExpr
      | BinaryOperator | CompoundAssignOperator | UnaryOperator
        ->
          expr env (enum, l, xs)
      | _ -> 
          sexps env xs
      )
  | Angle (xs)   -> sexps env xs
  | Anchor (xs)  -> sexps env xs
  | Bracket (xs) -> sexps env xs
  | Brace (_xs, _) -> ()
  | T _tok -> ()

and sexp env x =
  sexp_toplevel { env with at_toplevel = false} x

and sexps env xs = List.iter (sexp env) xs

(* ---------------------------------------------------------------------- *)
(* Decls *)
(* ---------------------------------------------------------------------- *)

(* coupling: must add constructor in dispatcher above if add a case here *)
and decl env (enum, _l, xs) =
  let env =
    match enum, xs with
    | FunctionDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::typ::rest->
        let kind = 
          if rest +> List.exists (function 
          | Paren (CompoundStmt, _, _) -> true
          | _ -> false
          )
          then E.Function
          else E.Prototype
        in
        let static = 
          match rest with
          (* if we are in an header file, then we don't want to rename
           * the inline static function because of uninclude_clang which
           * splitted in different files, and so with different
           * local_rename hash. Renaming in the header file would lead to
           * some unresolved lookup in the c files.
           *)
          | T (TLowerIdent "static")::T (TLowerIdent "inline")::_rest ->
              kind_file env =*= Source
          | T (TLowerIdent "static")::_rest -> true
          | _ when s = "main" -> true
          | _ -> false
        in
        let s = 
          if static && kind = E.Function 
          then new_str_if_defs env s 
          else s 
        in
        (* todo: when static and prototype, we should create a new_str_if_defs
         * that will match the one created later for the Function, but
         * right now we just don't create the node, it's simpler.
         *)
        let env = 
          if static && kind = E.Prototype
          then env
          (* todo: when prototype and in .c, then it's probably a forward
           * decl that we could just skip?
           *)
          else add_node_and_edge_if_defs_mode env (s, kind) 
        in
        if kind <> E.Prototype then add_type_deps env typ;
        { env with locals = ref [] }

    | VarDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::typ::rest ->
        let kind =
          match rest with
          | T (TLowerIdent "extern")::_ -> E.GlobalExtern
          (* less: print a warning they should put extern decl *)
          | [] when kind_file env = Header -> E.GlobalExtern
          (* when have 'int x = 1;' in a header, it's actually the def.
           * less: print a warning asking to mv in a .c
           *)
          | [(Paren _)] when kind_file env = Header -> E.Global
          | _ -> E.Global
        in
        let static = 
          match rest with
          | T (TLowerIdent "static")::_rest -> kind_file env =*= Source
          | _ -> false
        in
        let env =
          if env.at_toplevel 
          then 
            let s = if static then new_str_if_defs env s else s in
            add_node_and_edge_if_defs_mode env (s, kind)
          else begin
            if kind <> E.GlobalExtern
            then env.locals := s::!(env.locals);
            env
          end
        in
        if kind <> E.GlobalExtern then add_type_deps env typ;
        env

    (* I am not sure about the namespaces, so I prepend strings *)
    | TypedefDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::typ::_rest ->
        if env.phase = Defs 
        then begin
          (* populate env.typedefs, ensure first have same body *)
          let loc = loc_of_env env in
          let toks = 
            Type_clang.tokens_of_brace_sexp env.conf.typedefs_dependencies 
              loc typ in
          let t = 
            Type_clang.type_of_tokens loc toks in
          if Hashtbl.mem env.typedefs s
          then
            let old = Hashtbl.find env.typedefs s in
            if old =*= t
            then ()
            else env.pr2_and_log (spf "conflicting typedefs for %s, %s <> %s" 
                                    s (Common.dump old) (Common.dump t))
          (* todo: if are in Source, then maybe can add in local_typedefs *)
          else Hashtbl.add env.typedefs s t
        end;
        let env = add_node_and_edge_if_defs_mode env ("T__" ^ s, E.Type) in
        (* add_type_deps env typ; *)
        env
        
    | EnumDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::_rest ->
        add_node_and_edge_if_defs_mode env ("E__" ^ s, E.Type) 

    (* ignore forward decl, to avoid duped entities *)
    | RecordDecl, _loc::(T (TLowerIdent ("struct" | "union")))
        ::(T (TLowerIdent _s | TUpperIdent _s))::[] ->
        env
    (* regular defs *)
    | RecordDecl, _loc::(T (TLowerIdent "struct"))
        ::(T (TLowerIdent s | TUpperIdent s))::_rest ->
        add_node_and_edge_if_defs_mode env ("S__" ^ s, E.Type)
    | RecordDecl, _loc::(T (TLowerIdent "union"))
        ::(T (TLowerIdent s | TUpperIdent s))::_rest ->
        add_node_and_edge_if_defs_mode env ("U__" ^ s, E.Type)
    (* usually embedded struct *)
    | RecordDecl, loc::(T (TLowerIdent "struct"))::_rest ->
        add_node_and_edge_if_defs_mode env 
          (spf "S__anon__%s" (str_of_angle_loc env loc), E.Type)
          
    (* todo: usually there is a typedef just behind *)
    | EnumDecl, loc::_rest ->
        add_node_and_edge_if_defs_mode env 
          (spf "E__anon__%s" (str_of_angle_loc env loc), E.Type)
    | RecordDecl, loc::(T (TLowerIdent "union"))::_rest ->
        add_node_and_edge_if_defs_mode env 
          (spf "U__anon__%s" (str_of_angle_loc env loc), E.Type)

    | FieldDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::typ::_rest ->
        let env = add_node_and_edge_if_defs_mode env (s, E.Field) in 
        add_type_deps env typ;
        env
    | FieldDecl, loc::_rest ->
        add_node_and_edge_if_defs_mode env 
          (spf "F__anon__%s" (str_of_angle_loc env loc), E.Field)

    | EnumConstantDecl, _loc::(T (TLowerIdent s | TUpperIdent s))::_rest ->
        let s = if kind_file env =*= Source then new_str_if_defs env s else s in
        add_node_and_edge_if_defs_mode env (s, E.Constructor)
        
    | _ -> error env "wrong Decl line" 
  in
  sexps env xs

(* ---------------------------------------------------------------------- *)
(* Stmt *)
(* ---------------------------------------------------------------------- *)
(* stmts does not define nor use any entities (expressions do), so the
 * regular visitor will go through them without doing anything.
 *)

(* ---------------------------------------------------------------------- *)
(* Expr *)
(* ---------------------------------------------------------------------- *)

(* coupling: must add constructor in dispatcher above if add one case here *)
and expr env (enum, _l, xs) =
  (match enum, xs with
  | CallExpr, _loc::_typ
      ::(Paren (ImplicitCastExpr, _l2, 
             _loc2::_typ2::Angle _::
               (Paren (DeclRefExpr, _l3,
                      _loc3::_typ3::T (TUpperIdent "Function")::T (THexInt _)
                        ::T (TString s)::_typ4::[]))::[]))
      ::_args ->
      if env.phase = Uses
      then add_use_edge env (str env s, E.Function)

  (* todo: unexpected form of call? function pointer call? add to stats *)
  | CallExpr, _ -> ()

  | DeclRefExpr, _loc::_typ::T (TUpperIdent "EnumConstant")::_address
      ::T (TString s)::_rest ->
      if env.phase = Uses
      then  add_use_edge env (str env s, E.Constructor)

  | DeclRefExpr, _loc::_typ::_lval::T (TUpperIdent "Var")::_address
      ::T (TString s)::_rest ->
      if env.phase = Uses
      then
        if List.mem s !(env.locals)
        then ()
        else add_use_edge env (str env s, E.Global)

  | DeclRefExpr, _loc::_typ::_lval::T (TUpperIdent "ParmVar")::_rest -> 
      ()

  | DeclRefExpr, _loc::_typ::T (TUpperIdent "Function")::_address
      ::T (TString s)::_rest 
  | DeclRefExpr, _loc::_typ::T (TLowerIdent "lvalue")
      ::T (TUpperIdent "Function")::_address
      ::T (TString s)::_rest 
      ->
      if env.phase = Uses
      then add_use_edge env (str env s, E.Function)
        
  | DeclRefExpr, _loc::_typ::T (TLowerIdent "lvalue")
      ::T (TUpperIdent "CXXMethod")::_rest
      -> pr2_once "CXXMethod not handled"
     
  | DeclRefExpr, _ -> error env "DeclRefExpr to handle"

  (* note: _address could be useful to know precisely to which field we
   * access, but such an address can't be deduped in uninclude. Fortunately
   * we can look at the type of the subexpression (see enum2 below) to
   * infer the structure the field refers to.
  *)
  | MemberExpr, [_loc;_typ;_(*lval*);T (TDot|TArrow);
                 T (TLowerIdent fld|TUpperIdent fld);
                 _address;(Paren (enum2, l2, xs))]
  | MemberExpr, [_loc;_typ;T (TDot|TArrow);
                 T (TLowerIdent fld | TUpperIdent fld);
                 _address;(Paren (enum2, l2, xs))]
  | MemberExpr, [_loc;_typ;_(*lval*);T (TLowerIdent "bitfield");T(TDot|TArrow);
                 T (TLowerIdent fld | TUpperIdent fld);
                 _address;(Paren (enum2, l2, xs))] ->
      if env.phase = Uses && env.conf.fields_dependencies
      then
        let loc = env.clang2_file, l2 in
        (* todo1: use expand_type there too *)
        let toks = Type_clang.tokens_of_paren_sexp loc (Paren(enum2, l2, xs))in
        let typ_subexpr = Type_clang.type_of_tokens loc toks in
        let typ_subexpr = Type_clang.expand_typedefs env.typedefs typ_subexpr in
        (match typ_subexpr with
        (* because TDot|TArrow above, need Pointer too *)
        | Typ.StructName s | Typ.Pointer (Typ.StructName s) ->
            add_use_edge env (spf "S__%s.%s" s fld, E.Field)

        (* with some struct anon this can happen apparently, cf umalloc.c *)
        | Typ.Typename s | Typ.Pointer (Typ.Typename s) ->
            env.pr2_and_log (spf "member access to typedef not expanded: %s" s)

        | Typ.TypeofStuff | Typ.Pointer (Typ.TypeofStuff) ->
            error env ("impossible")

        (* todo? should add deps no? *)
        | Typ.UnionName _s  | Typ.Pointer (Typ.UnionName _s) -> ()
        (* todo? *)
        | Typ.AnonStuff | Typ.Pointer (Typ.AnonStuff) -> ()

        | (Typ.Builtin _ |Typ.Function _ |Typ.EnumName _ |Typ.Other _ 
          |Typ.Pointer _
          ) ->
            error env (spf "unhandled typ: %s" (Common.dump typ_subexpr))
        )

  (* anon field *)
  | MemberExpr, _loc::_typ::_lval::T (TDot|TArrow)::
      _address::(Paren (_enum2, _l2, _xs))::[] ->
      if env.phase = Uses
      then ()

  | MemberExpr, _ -> error env "MemberExpr to handle"

  | UnaryExprOrTypeTraitExpr, _loc::_typ::T(TLowerIdent "sizeof")::typ::_rest ->
      (match typ with
      | Paren _ -> ()
      | Brace _ -> add_type_deps env typ
      | _ -> error env "wrong argument to sizeof"
      )
  | (BinaryOperator | CompoundAssignOperator | UnaryOperator
    ), _ -> ()

  | _ -> error env "Impossible, see dispatcher"
  );
  
  (* mostly for generating use/read or use/write in prolog *)
  (match enum, xs with
  | BinaryOperator, _loc::_typ::T(TString "=")::e1::e2::[] 
  | CompoundAssignOperator, _loc::_typ::_::  _::_::_::_::_::_::e1::e2::[]
    ->
     sexps { env with in_assign = true } [e1];
     sexps env [e2];
  (* potentially here we would like to treat as both a write and read
   * of the variable, so maybe a trivalue would be better than a boolean
   *)
  | UnaryOperator, _loc::_typ::_inf_or_post::T(TString ("++"|"--"))::e::[] ->
     sexps { env with in_assign = true } [e];
  | UnaryOperator, _loc::_typ::_inf_or_post::T(TString ("&"))::e::[] ->
     sexps { env with in_assign = true } [e];


  | _ -> 
    sexps env xs
  )

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let build ?(verbose=true) root files =
  if null files 
  then failwith "no .clang2 files, run pfff -uninclude_clang";

  let g = G.create () in
  G.create_initial_hierarchy g;

  let chan = open_out (Filename.concat root "pfff.log") in
  (* file -> (string, string) Hashtbl *)
  let local_renames_of_files = Hashtbl.create 101 in
  (* less: we could also have a local_typedefs_of_files to avoid conflicts *)
  
  let conf = {
    typedefs_dependencies = false;
    types_dependencies = true;
    fields_dependencies = true;
    propagate_deps_def_to_decl = false;
  } in

  let env = {
    g;
    phase = Defs;
    current = unknown_location;

    c_file_readable = "__filled_later__";
    c_file_absolute = "__filled_later__";
    current_c_line = ref 1;
    current_c_file = ref "__filled_later__";
    clang2_file = "__filled_later__";
    clang_line = -1;

    root = root;
    at_toplevel = true;
    in_assign = false;
    local_rename = Hashtbl.create 0;
    dupes = Hashtbl.create 101;
    conf;
    typedefs = Hashtbl.create 101;
    locals = ref [];

    log = (fun s -> output_string chan (s ^ "\n"); flush chan;);
    pr2_and_log = (fun s ->
      (*if verbose then *)
      pr2 s;
      output_string chan (s ^ "\n"); flush chan;
    );
  } in

  G.add_node unknown_location g;
  G.add_edge (G.not_found, unknown_location) G.Has g;
  
  (* step1: creating the nodes and 'Has' edges, the defs *)
  env.pr2_and_log "\nstep1: extract defs";
  files +> Console.progress ~show:verbose (fun k ->
    List.iter (fun file ->
      k();
      let ast = parse file in
      let local_rename = Hashtbl.create 101 in
      Hashtbl.add local_renames_of_files file local_rename;
      extract_defs_uses { env with 
        phase = Defs; 
        clang2_file = file;
        local_rename = local_rename;
      } ast
   ));

  (* step2: creating the 'Use' edges *)
  env.pr2_and_log "\nstep2: extract Uses";
  files +> Console.progress ~show:verbose (fun k ->
    List.iter (fun file ->
      k();
      let ast = parse file in
      extract_defs_uses { env with 
        phase = Uses; 
        clang2_file = file;
        local_rename = Hashtbl.find local_renames_of_files file;
      } ast
    ));

  env.pr2_and_log "\nstep3: adjusting";
  if conf.propagate_deps_def_to_decl
  then propagate_users_of_functions_globals_types_to_prototype_extern_typedefs g;
  G.remove_empty_nodes g [unknown_location; G.not_found; G.dupe; G.pb];

  g
