(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** Module for the checks called by Eradicate. *)

let report_error tenv = TypeErr.report_error tenv (EradicateCheckers.report_error tenv)

let explain_expr tenv node e =
  match Errdesc.exp_rv_dexp tenv node e with
  | Some de ->
      Some (DecompiledExp.to_string de)
  | None ->
      None


let is_virtual = function
  | AnnotatedSignature.{mangled} :: _ when Mangled.is_this mangled ->
      true
  | _ ->
      false


let check_object_dereference ~nullsafe_mode tenv find_canonical_duplicate curr_pname node instr_ref
    object_exp dereference_type inferred_nullability loc =
  Result.iter_error
    (DereferenceRule.check ~nullsafe_mode
       (InferredNullability.get_nullability inferred_nullability))
    ~f:(fun dereference_violation ->
      let nullable_object_origin = InferredNullability.get_origin inferred_nullability in
      let nullable_object_descr = explain_expr tenv node object_exp in
      let type_error =
        TypeErr.Nullable_dereference
          { dereference_violation
          ; dereference_location= loc
          ; nullable_object_descr
          ; dereference_type
          ; nullable_object_origin }
      in
      report_error tenv find_canonical_duplicate type_error (Some instr_ref) loc curr_pname )


(** Where the condition is coming from *)
type from_call =
  | From_condition  (** Direct condition *)
  | From_instanceof  (** x instanceof C *)
  | From_is_false_on_null  (** returns false on null *)
  | From_is_true_on_null  (** returns true on null *)
  | From_containsKey  (** x.containsKey *)
[@@deriving compare]

let equal_from_call = [%compare.equal: from_call]

(** [expr] is an expression that was explicitly compared with `null`. At the same time, [expr] had
    [inferred_nullability] before the comparision. Check if the comparision is redundant and emit an
    issue, if this is the case. *)
let check_condition_for_redundancy tenv ~is_always_true find_canonical_duplicate curr_pdesc node
    expr typ inferred_nullability idenv linereader loc instr_ref : unit =
  let contains_instanceof_throwable pdesc node =
    (* Check if the current procedure has a catch Throwable. *)
    (* That always happens in the bytecode generated by try-with-resources. *)
    let loc = Procdesc.Node.get_loc node in
    let throwable_found = ref false in
    let typ_is_throwable {Typ.desc} =
      match desc with
      | Typ.Tstruct (Typ.JavaClass _ as name) ->
          String.equal (Typ.Name.name name) "java.lang.Throwable"
      | _ ->
          false
    in
    let do_instr = function
      | Sil.Call (_, Exp.Const (Const.Cfun pn), [_; (Exp.Sizeof {typ}, _)], _, _)
        when Procname.equal pn BuiltinDecl.__instanceof && typ_is_throwable typ ->
          throwable_found := true
      | _ ->
          ()
    in
    let do_node n =
      if Location.equal loc (Procdesc.Node.get_loc n) then
        Instrs.iter ~f:do_instr (Procdesc.Node.get_instrs n)
    in
    Procdesc.iter_nodes do_node pdesc ; !throwable_found
  in
  let from_try_with_resources () : bool =
    (* heuristic to check if the condition is the translation of try-with-resources *)
    match Printer.LineReader.from_loc linereader loc with
    | Some line ->
        (not (String.is_substring ~substring:"==" line || String.is_substring ~substring:"!=" line))
        && String.is_substring ~substring:"}" line
        && contains_instanceof_throwable curr_pdesc node
    | None ->
        false
  in
  let is_temp = Idenv.exp_is_temp idenv expr in
  let should_report =
    (* NOTE: We have different levels of non-nullability. In practice there is a big difference
       between certainty for different cases: whether expression is the result of something that can not be null
       due to language semantics, or comes from something that is merely not declared as nullable.
       We report both types of issues now, which is OK since this warning is turned off by default.
       In the future we might as well start reporting only for cases where we are more confident.
       Hovewer keep in mind that for code analysis purposes all condition redudant warnings can be useful,
       particularly they help to find popular functions that should have been annotated as nullable, but were not made so.
    *)
    (* NOTE: We don't report the opposite case, namely when the expression is known to be always `null`. Consider changing this.
    *)
    InferredNullability.is_nonnull_or_declared_nonnull inferred_nullability
    && Config.eradicate_condition_redundant && (not is_temp) && PatternMatch.type_is_class typ
    && (not (from_try_with_resources ()))
    && not (InferredNullability.origin_is_fun_library inferred_nullability)
  in
  if should_report then
    (* TODO(T61051649) this is not really condition. This is an expression.
       This leads to inconsistent messaging like "condition `some_variable` is always true".
       So Condition_redundant should either accept expression, or this should pass a condition.
    *)
    let condition_descr = explain_expr tenv node expr in
    let nonnull_origin = InferredNullability.get_origin inferred_nullability in
    report_error tenv find_canonical_duplicate
      (TypeErr.Condition_redundant {is_always_true; condition_descr; nonnull_origin})
      (Some instr_ref) loc curr_pdesc


(** Check an assignment to a field. *)
let check_field_assignment ~nullsafe_mode tenv find_canonical_duplicate curr_pdesc node instr_ref
    typestate exp_lhs exp_rhs typ loc fname annotated_field_opt typecheck_expr : unit =
  let curr_pname = Procdesc.get_proc_name curr_pdesc in
  let curr_pattrs = Procdesc.get_attributes curr_pdesc in
  let t_lhs, inferred_nullability_lhs =
    typecheck_expr node instr_ref curr_pdesc typestate exp_lhs
      (* TODO(T54687014) optimistic default might be an unsoundness issue - investigate *)
      (typ, InferredNullability.create TypeOrigin.OptimisticFallback)
      loc
  in
  let _, inferred_nullability_rhs =
    typecheck_expr node instr_ref curr_pdesc typestate exp_rhs
      (* TODO(T54687014) optimistic default might be an unsoundness issue - investigate *)
      (typ, InferredNullability.create TypeOrigin.OptimisticFallback)
      loc
  in
  let field_is_injector_readwrite () =
    match annotated_field_opt with
    | Some AnnotatedField.{annotation_deprecated} ->
        Annotations.ia_is_field_injector_readwrite annotation_deprecated
    | _ ->
        false
  in
  let field_is_in_cleanup_context () =
    let AnnotatedSignature.{ret_annotation_deprecated} =
      (Models.get_modelled_annotated_signature tenv curr_pattrs).ret
    in
    Annotations.ia_is_cleanup ret_annotation_deprecated
  in
  let assignment_check_result =
    AssignmentRule.check ~nullsafe_mode
      ~lhs:(InferredNullability.get_nullability inferred_nullability_lhs)
      ~rhs:(InferredNullability.get_nullability inferred_nullability_rhs)
  in
  Result.iter_error assignment_check_result ~f:(fun assignment_violation ->
      let should_report =
        (not (AndroidFramework.is_destroy_method curr_pname))
        && PatternMatch.type_is_class t_lhs
        && (not (Fieldname.is_java_outer_instance fname))
        && (not (field_is_injector_readwrite ()))
        && not (field_is_in_cleanup_context ())
      in
      if should_report then
        let rhs_origin = InferredNullability.get_origin inferred_nullability_rhs in
        report_error tenv find_canonical_duplicate
          (TypeErr.Bad_assignment
             { assignment_violation
             ; assignment_location= loc
             ; rhs_origin
             ; assignment_type= AssignmentRule.AssigningToField fname })
          (Some instr_ref) loc curr_pdesc )


let is_declared_nonnull AnnotatedField.{annotated_type} =
  match annotated_type.nullability with
  | AnnotatedNullability.Nullable _ ->
      false
  | AnnotatedNullability.UncheckedNonnull _ ->
      true
  | AnnotatedNullability.StrictNonnull _ ->
      true


(* Is field declared as non-nullable (implicitly or explicitly)? *)
let is_field_declared_as_nonnull annotated_field_opt =
  (* If the field is not present, we optimistically assume it is not nullable.
     TODO(T54687014) investigate if this leads to unsoundness issues in practice
  *)
  Option.exists annotated_field_opt ~f:is_declared_nonnull


let lookup_field_in_typestate pname field_name typestate =
  let pvar = Pvar.mk (Mangled.from_string (Fieldname.to_string field_name)) pname in
  TypeState.lookup_pvar pvar typestate


(* Given a predicate over field name, look ups the field and returns a predicate
  over this field value in a typestate, or true if there is no such a field in typestate *)
let convert_predicate predicate_over_field_name field_name (pname, typestate) =
  let range_for_field = lookup_field_in_typestate pname field_name typestate in
  Option.exists range_for_field ~f:predicate_over_field_name


(* Given a list of typestates, does a given predicate about the field hold for at least one of them? *)
let predicate_holds_for_some_typestate typestate_list field_name ~predicate =
  List.exists typestate_list ~f:(convert_predicate predicate field_name)


(* Given the typestate and the field, what is the upper bound of field nullability in this typestate?
 *)
let get_nullability_upper_bound_for_typestate proc_name field_name typestate =
  let range_for_field = lookup_field_in_typestate proc_name field_name typestate in
  match range_for_field with
  | None ->
      (* There is no information about the field type in typestate (field was not assigned in all paths).
         It gives the most generic upper bound.
      *)
      Nullability.top
  (* We were able to lookup the field. Its nullability gives precise upper bound. *)
  | Some (_, inferred_nullability) ->
      InferredNullability.get_nullability inferred_nullability


(* Given the list of typestates (each corresponding to the final result of executing of some function),
   and the field, what is the upper bound of field nullability joined over all typestates?
 *)
let get_nullability_upper_bound field_name typestate_list =
  (* Join upper bounds for all typestates in the list *)
  List.fold typestate_list ~init:Nullability.StrictNonnull ~f:(fun acc (proc_name, typestate) ->
      Nullability.join acc
        (get_nullability_upper_bound_for_typestate proc_name field_name typestate) )


(** Check field initialization for a given constructor *)
let check_constructor_initialization tenv find_canonical_duplicate curr_constructor_pname
    curr_constructor_pdesc start_node ~nullsafe_mode
    ~typestates_for_curr_constructor_and_all_initializer_methods
    ~typestates_for_all_constructors_incl_current loc : unit =
  State.set_node start_node ;
  if Procname.is_constructor curr_constructor_pname then
    match
      PatternMatch.get_this_type_nonstatic_methods_only
        (Procdesc.get_attributes curr_constructor_pdesc)
    with
    | Some {desc= Tptr (({desc= Tstruct name} as ts), _)} -> (
      match Tenv.lookup tenv name with
      | Some {fields} ->
          let do_field (field_name, field_type, _) =
            let annotated_field = AnnotatedField.get tenv field_name ts in
            let is_injector_readonly_annotated =
              match annotated_field with
              | None ->
                  false
              | Some {annotation_deprecated} ->
                  Annotations.ia_is_field_injector_readonly annotation_deprecated
            in
            let is_initialized_in_either_constructor_or_initializer =
              let is_initialized = function
                | TypeOrigin.Undef ->
                    (* Special case: not really an initialization *)
                    false
                | TypeOrigin.Field {object_origin= TypeOrigin.This} ->
                    (* Circular initialization - does not count *)
                    false
                | _ ->
                    (* Found in typestate, hence the field was initialized *)
                    true
              in
              predicate_holds_for_some_typestate
                (Lazy.force typestates_for_curr_constructor_and_all_initializer_methods) field_name
                ~predicate:(fun (_, nullability) ->
                  is_initialized (InferredNullability.get_origin nullability) )
            in
            (* TODO(T54584721) This check is completely independent of the current constuctor we check.
               This check should be moved out of this function. Until it is done,
               we issue one over-annotated warning per constructor, which does not make a lot of sense. *)
            let field_nullability_upper_bound_over_all_typestates () =
              get_nullability_upper_bound field_name
                (Lazy.force typestates_for_all_constructors_incl_current)
            in
            let should_check_field_initialization =
              let in_current_class =
                let fld_cname = Fieldname.get_class_name field_name in
                Typ.Name.equal name fld_cname
              in
              (not is_injector_readonly_annotated)
              (* primitive types can not be null so initialization check is not needed *)
              && PatternMatch.type_is_class field_type
              && in_current_class
              && not (Fieldname.is_java_outer_instance field_name)
            in
            if should_check_field_initialization then (
              (* Check if non-null field is not initialized. *)
              if
                is_field_declared_as_nonnull annotated_field
                && not is_initialized_in_either_constructor_or_initializer
              then
                if
                  Config.nullsafe_disable_field_not_initialized_in_nonstrict_classes
                  && NullsafeMode.equal nullsafe_mode NullsafeMode.Default
                then
                  (* Behavior needed for backward compatibility, where we are not ready to surface this type of errors by default.
                     Hovewer, this error should be always turned on for @NullsafeStrict classes.
                  *)
                  ()
                else
                  report_error tenv find_canonical_duplicate
                    (TypeErr.Field_not_initialized {nullsafe_mode; field_name})
                    None loc curr_constructor_pdesc ;
              (* Check if field is over-annotated. *)
              match annotated_field with
              | None ->
                  ()
              | Some annotated_field ->
                  if Config.eradicate_field_over_annotated then
                    let what =
                      AnnotatedNullability.get_nullability
                        annotated_field.annotated_type.nullability
                    in
                    let by_rhs_upper_bound = field_nullability_upper_bound_over_all_typestates () in
                    Result.iter_error (OverAnnotatedRule.check ~what ~by_rhs_upper_bound)
                      ~f:(fun over_annotated_violation ->
                        report_error tenv find_canonical_duplicate
                          (TypeErr.Over_annotation
                             { over_annotated_violation
                             ; violation_type= OverAnnotatedRule.FieldOverAnnoted field_name })
                          None loc curr_constructor_pdesc ) )
          in
          List.iter ~f:do_field fields
      | None ->
          () )
    | _ ->
        ()


let check_return_not_nullable ~nullsafe_mode tenv find_canonical_duplicate loc curr_pname curr_pdesc
    (ret_signature : AnnotatedSignature.ret_signature) ret_inferred_nullability =
  (* Returning from a function is essentially an assignment the actual return value to the formal `return` *)
  let lhs = AnnotatedNullability.get_nullability ret_signature.ret_annotated_type.nullability in
  let rhs = InferredNullability.get_nullability ret_inferred_nullability in
  Result.iter_error (AssignmentRule.check ~nullsafe_mode ~lhs ~rhs) ~f:(fun assignment_violation ->
      let rhs_origin = InferredNullability.get_origin ret_inferred_nullability in
      report_error tenv find_canonical_duplicate
        (TypeErr.Bad_assignment
           { assignment_violation
           ; assignment_location= loc
           ; rhs_origin
           ; assignment_type= AssignmentRule.ReturningFromFunction curr_pname })
        None loc curr_pdesc )


let check_return_overrannotated tenv find_canonical_duplicate loc curr_pname curr_pdesc
    (ret_signature : AnnotatedSignature.ret_signature) ret_inferred_nullability =
  (* Returning from a function is essentially an assignment the actual return value to the formal `return` *)
  let what = AnnotatedNullability.get_nullability ret_signature.ret_annotated_type.nullability in
  (* In our CFG implementation, there is only one place where we return from a function
     (all execution flow joins are already made), hence inferreed nullability of returns gives us
     correct upper bound.
  *)
  let by_rhs_upper_bound = InferredNullability.get_nullability ret_inferred_nullability in
  Result.iter_error (OverAnnotatedRule.check ~what ~by_rhs_upper_bound)
    ~f:(fun over_annotated_violation ->
      report_error tenv find_canonical_duplicate
        (TypeErr.Over_annotation
           { over_annotated_violation
           ; violation_type= OverAnnotatedRule.ReturnOverAnnotated curr_pname })
        None loc curr_pdesc )


(** Check the annotations when returning from a method. *)
let check_return_annotation tenv find_canonical_duplicate curr_pdesc ret_range
    (annotated_signature : AnnotatedSignature.t) ret_implicitly_nullable loc : unit =
  let curr_pname = Procdesc.get_proc_name curr_pdesc in
  match ret_range with
  (* Disables the warnings since it is not clear how to annotate the return value of lambdas *)
  | Some _
    when match curr_pname with
         | Procname.Java java_pname ->
             Procname.Java.is_lambda java_pname
         | _ ->
             false ->
      ()
  | Some (_, ret_inferred_nullability) ->
      (* TODO(T54308240) Model ret_implicitly_nullable in AnnotatedNullability *)
      if not ret_implicitly_nullable then
        check_return_not_nullable ~nullsafe_mode:annotated_signature.nullsafe_mode tenv
          find_canonical_duplicate loc curr_pname curr_pdesc annotated_signature.ret
          ret_inferred_nullability ;
      if Config.eradicate_return_over_annotated then
        check_return_overrannotated tenv find_canonical_duplicate loc curr_pname curr_pdesc
          annotated_signature.ret ret_inferred_nullability
  | None ->
      ()


(** Check the receiver of a virtual call. *)
let check_call_receiver ~nullsafe_mode tenv find_canonical_duplicate curr_pdesc node typestate
    call_params callee_pname (instr_ref : TypeErr.InstrRef.t) loc typecheck_expr : unit =
  match call_params with
  | ((original_this_e, this_e), typ) :: _ ->
      let _, this_inferred_nullability =
        typecheck_expr tenv node instr_ref curr_pdesc typestate this_e
          (* TODO(T54687014) optimistic default might be an unsoundness issue - investigate *)
          (typ, InferredNullability.create TypeOrigin.OptimisticFallback)
          loc
      in
      check_object_dereference ~nullsafe_mode tenv find_canonical_duplicate curr_pdesc node
        instr_ref original_this_e (DereferenceRule.MethodCall callee_pname)
        this_inferred_nullability loc
  | [] ->
      ()


type resolved_param =
  { num: int
  ; formal: AnnotatedSignature.param_signature
  ; actual: Exp.t * InferredNullability.t
  ; is_formal_propagates_nullable: bool }

let is_third_party_via_sig_files proc_name =
  Option.is_some
    (ThirdPartyAnnotationInfo.lookup_related_sig_file_by_package
       (ThirdPartyAnnotationGlobalRepo.get_repo ())
       proc_name)


let is_marked_third_party_in_config proc_name =
  match proc_name with
  | Procname.Java java_pname ->
      (* TODO: migrate to the new way of checking for third party: use
         signatures repository instead of looking it up in config params.
      *)
      Procname.Java.is_external java_pname
  | _ ->
      false


(* if this method belongs to a third party code, but is not modelled neigher internally nor externally *)
let is_third_party_without_model proc_name model_source =
  let is_third_party =
    is_third_party_via_sig_files proc_name || is_marked_third_party_in_config proc_name
  in
  is_third_party && Option.is_none model_source


(** Check the parameters of a call. *)
let check_call_parameters ~nullsafe_mode ~callee_annotated_signature tenv find_canonical_duplicate
    curr_pdesc node callee_attributes resolved_params loc instr_ref : unit =
  let callee_pname = callee_attributes.ProcAttributes.proc_name in
  let check {num= param_position; formal; actual= orig_e2, nullability_actual} =
    let report assignment_violation =
      let actual_param_expression =
        match explain_expr tenv node orig_e2 with
        | Some descr ->
            descr
        | None ->
            "formal parameter " ^ Mangled.to_string formal.mangled
      in
      let rhs_origin = InferredNullability.get_origin nullability_actual in
      report_error tenv find_canonical_duplicate
        (TypeErr.Bad_assignment
           { assignment_violation
           ; assignment_location= loc
           ; rhs_origin
           ; assignment_type=
               AssignmentRule.PassingParamToFunction
                 { param_signature= formal
                 ; model_source= callee_annotated_signature.AnnotatedSignature.model_source
                 ; actual_param_expression
                 ; param_position
                 ; function_procname= callee_pname } })
        (Some instr_ref) loc curr_pdesc
    in
    if PatternMatch.type_is_class formal.param_annotated_type.typ then
      (* Passing a param to a function is essentially an assignment the actual param value
         to the formal param *)
      let lhs = AnnotatedNullability.get_nullability formal.param_annotated_type.nullability in
      let rhs = InferredNullability.get_nullability nullability_actual in
      Result.iter_error (AssignmentRule.check ~nullsafe_mode ~lhs ~rhs) ~f:report
  in
  let should_ignore_parameters_check =
    (* TODO(T52947663) model params in third-party non modelled method as a dedicated nullability type,
       so this logic can be moved to [AssignmentRule.check] *)
    NullsafeMode.equal nullsafe_mode NullsafeMode.Default
    && Config.nullsafe_optimistic_third_party_params_in_non_strict
    && is_third_party_without_model callee_pname
         callee_annotated_signature.AnnotatedSignature.model_source
  in
  if not should_ignore_parameters_check then
    (* left to right to avoid guessing the different lengths *)
    List.iter ~f:check resolved_params


let check_inheritance_rule_for_return find_canonical_duplicate tenv loc ~nullsafe_mode
    ~base_proc_name ~overridden_proc_name ~overridden_proc_desc ~base_nullability
    ~overridden_nullability =
  Result.iter_error
    (InheritanceRule.check ~nullsafe_mode InheritanceRule.Ret ~base:base_nullability
       ~overridden:overridden_nullability) ~f:(fun inheritance_violation ->
      report_error tenv find_canonical_duplicate
        (TypeErr.Inconsistent_subclass
           { inheritance_violation
           ; violation_type= InheritanceRule.InconsistentReturn
           ; overridden_proc_name
           ; base_proc_name })
        None loc overridden_proc_desc )


let check_inheritance_rule_for_param find_canonical_duplicate tenv loc ~nullsafe_mode
    ~overridden_param_name ~base_proc_name ~overridden_proc_name ~overridden_proc_desc
    ~param_position ~base_nullability ~overridden_nullability =
  Result.iter_error
    (InheritanceRule.check ~nullsafe_mode InheritanceRule.Param ~base:base_nullability
       ~overridden:overridden_nullability) ~f:(fun inheritance_violation ->
      report_error tenv find_canonical_duplicate
        (TypeErr.Inconsistent_subclass
           { inheritance_violation
           ; violation_type=
               InheritanceRule.InconsistentParam
                 {param_position; param_description= Mangled.to_string overridden_param_name}
           ; base_proc_name
           ; overridden_proc_name })
        None loc overridden_proc_desc )


let check_inheritance_rule_for_params find_canonical_duplicate tenv loc ~nullsafe_mode
    ~base_proc_name ~overridden_proc_name ~overridden_proc_desc ~base_signature
    ~overridden_signature =
  let base_params = base_signature.AnnotatedSignature.params in
  let overridden_params = overridden_signature.AnnotatedSignature.params in
  let zipped_params = List.zip base_params overridden_params in
  match zipped_params with
  | Ok base_and_overridden_params ->
      let should_index_from_zero = is_virtual base_params in
      (* Check the rule for each pair of base and overridden param *)
      List.iteri base_and_overridden_params
        ~f:(fun index
           ( AnnotatedSignature.{param_annotated_type= {nullability= annotated_nullability_base}}
           , AnnotatedSignature.
               { mangled= overridden_param_name
               ; param_annotated_type= {nullability= annotated_nullability_overridden} } )
           ->
          check_inheritance_rule_for_param find_canonical_duplicate tenv loc ~nullsafe_mode
            ~overridden_param_name ~base_proc_name ~overridden_proc_name ~overridden_proc_desc
            ~param_position:(if should_index_from_zero then index else index + 1)
            ~base_nullability:(AnnotatedNullability.get_nullability annotated_nullability_base)
            ~overridden_nullability:
              (AnnotatedNullability.get_nullability annotated_nullability_overridden) )
  | Unequal_lengths ->
      (* Skip checking.
         TODO (T5280249): investigate why argument lists can be of different length. *)
      ()


(* Check both params and return values for complying for co- and contravariance *)
let check_inheritance_rule_for_signature find_canonical_duplicate tenv loc ~nullsafe_mode
    ~base_proc_name ~overridden_proc_name ~overridden_proc_desc ~base_signature
    ~overridden_signature =
  (* Check params *)
  check_inheritance_rule_for_params find_canonical_duplicate tenv loc ~nullsafe_mode ~base_proc_name
    ~overridden_proc_name ~overridden_proc_desc ~base_signature ~overridden_signature ;
  (* Check return value *)
  match base_proc_name with
  (* TODO model this as unknown nullability and get rid of that check *)
  | Procname.Java java_pname when not (Procname.Java.is_external java_pname) ->
      (* Check if return value is consistent with the base *)
      let base_nullability =
        AnnotatedNullability.get_nullability
          base_signature.AnnotatedSignature.ret.ret_annotated_type.nullability
      in
      let overridden_nullability =
        AnnotatedNullability.get_nullability
          overridden_signature.AnnotatedSignature.ret.ret_annotated_type.nullability
      in
      check_inheritance_rule_for_return find_canonical_duplicate tenv loc ~nullsafe_mode
        ~base_proc_name ~overridden_proc_name ~overridden_proc_desc ~base_nullability
        ~overridden_nullability
  | _ ->
      (* the analysis should not report return type inconsistencies with external code *)
      ()


(** Checks if the annotations are consistent with the derived classes and with the implemented
    interfaces *)
let check_overridden_annotations find_canonical_duplicate tenv proc_name proc_desc
    annotated_signature =
  let start_node = Procdesc.get_start_node proc_desc in
  let loc = Procdesc.Node.get_loc start_node in
  let check_if_base_signature_matches_current base_proc_name =
    match PatternMatch.lookup_attributes tenv base_proc_name with
    | Some base_attributes ->
        let base_signature = Models.get_modelled_annotated_signature tenv base_attributes in
        check_inheritance_rule_for_signature
          ~nullsafe_mode:annotated_signature.AnnotatedSignature.nullsafe_mode
          find_canonical_duplicate tenv loc ~base_proc_name ~overridden_proc_name:proc_name
          ~overridden_proc_desc:proc_desc ~base_signature ~overridden_signature:annotated_signature
    | None ->
        (* Could not find the attributes - optimistically skipping the check *)
        (* TODO(T54687014) ensure this is not an issue in practice *)
        ()
  in
  (* Iterate over all methods the current method overrides and see the current
     method is compatible with all of them *)
  PatternMatch.override_iter check_if_base_signature_matches_current tenv proc_name
