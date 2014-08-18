(*
  Polynomial interpretations using Farkas' lemma.  Optionally with a minimal element

  @author Stephan Falke

  Copyright 2010-2014 Stephan Falke

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*)

module LSC = LocalSizeComplexity.Make(Rule)
module GSC = GlobalSizeComplexity.Make(Rule)
module TGraph = Tgraph.Make(Rule)
module CTRSObl = Ctrsobl.Make(Rule)
module CTRS = CTRSObl.CTRS
open CTRSObl
open CTRS

let rec getOnlyFor xx r s =
  match xx with
    | [] -> []
    | x::xs -> let rule = List.hd r in
                 if (Trs.contains s rule) then
                   x::(getOnlyFor xs (List.tl r) s)
                 else
                   getOnlyFor xs (List.tl r) s

(* Find a polynomial interpretation *)
let rec process useSizeComplexities useMinimal degree ctrsobl tgraph rvgraph =
  if degree < 0 || degree > 1 || CTRSObl.isSolved ctrsobl then
    None
  else
  (
    let globalSizeComplexities = if useSizeComplexities then GSC.compute ctrsobl (Utils.unboxOption rvgraph) else GSC.empty in
    let s = if useSizeComplexities then (constructAllS (getS4SizeComplexities tgraph ctrsobl)) else [CTRSObl.getUnknownComplexityRules ctrsobl] in
    doLoop useSizeComplexities useMinimal degree ctrsobl tgraph rvgraph globalSizeComplexities s
  )
and constructAllS s =
  let res = List.fold_left (fun rest e -> Utils.mapFlat (fun l -> [e::l; l]) rest) [[]] s in
  res
and doLoop useSizeComplexities useMinimal degree ctrsobl tgraph rvgraph globalSizeComplexities allS =
  let ctrs = ctrsobl.ctrs in
  let rules = ctrs.rules in
  if allS = [] then
    None
  else
  (
    let s = List.hd allS in
    Farkaspolo.lambda_count := 0;
    Farkaspolo.all_lambdas := [];
    let toOrient = if useSizeComplexities then s else rules in
    if toOrient = [] then
      doLoop useSizeComplexities useMinimal degree ctrsobl tgraph rvgraph globalSizeComplexities (List.tl allS)
    else
      let (abs, params) = Polo.create_poly_map degree toOrient in
      let (isMINs, isMINsVars) = if useMinimal then (create_is_mins toOrient) else ([], []) in
      let cwbs = Farkaspolo.convert_rules_to_leqs toOrient abs Big_int.unit_big_int in
      let cwbs_for_unknowns = getOnlyFor cwbs toOrient s in
      let weak = List.map Farkaspolo.getWeak cwbs in
      let weakRhsMin = if useMinimal then (List.map (getRhsMin isMINs) toOrient) else [] in
      let bound = List.map Farkaspolo.getBound cwbs_for_unknowns in
      let weakUseMinimal = if useMinimal then List.map2 (addNeitherMin isMINs) weak toOrient else [] in
      let boundUseMinimal = if useMinimal then List.map2 (addLhsNotMin isMINs) bound s else [] in
      let strictDecrease = List.map Farkaspolo.getStrict (getOnlyFor weak toOrient s) in
      let strictRhsNotMin = if useMinimal then (List.map (fun rule -> [getRhsNotMin isMINs rule]) s) else [] in
      let strictRhsMin = if useMinimal then (List.map (fun rule -> [getRhsMin isMINs rule]) s) else [] in
      let strict = if useMinimal then [] else (Farkaspolo.combine bound strictDecrease) in
      let strictUseMinimal = if useMinimal then (Farkaspolo.combine strictDecrease strictRhsNotMin) else [] in
      let allparams = params @ !Farkaspolo.all_lambdas @ isMINsVars in
      let res = 
        if useMinimal then 
          Smt.isSatisfiableFarkasPoloMinimal (getMinRestrictions isMINsVars) (getMinImplications isMINs abs) weakUseMinimal weakRhsMin boundUseMinimal strictUseMinimal strictRhsMin allparams
        else 
          Smt.isSatisfiableFarkasPolo (List.flatten weak) strict allparams
      in
      match res with
      | None -> None
      | Some model ->
        (
          let model' = Polo.fix_model model (params @ isMINsVars) in
          let conc = get_concrete_poly abs isMINs model' in
          let c = getC useSizeComplexities tgraph conc ctrsobl toOrient globalSizeComplexities in
          let nctrsobl = 
            if useMinimal then 
              annotateMinimal ctrsobl s boundUseMinimal strictUseMinimal strictRhsMin model' c
            else 
              annotate ctrsobl s strict model' c
          in
          if CTRSObl.haveSameComplexities ctrsobl nctrsobl then 
            (* Try next variant of S *)
            doLoop useSizeComplexities useMinimal degree ctrsobl tgraph rvgraph globalSizeComplexities (List.tl allS)
          else
            (
              Some ((nctrsobl, tgraph, rvgraph), getProof ctrsobl nctrsobl conc useSizeComplexities globalSizeComplexities toOrient)
            )
        )
  )

and getIsMIN isMINs f =
  Pc.Equ (Poly.fromVar (getMINmarker isMINs f), Poly.one)
and getIsNotMIN isMINs f =
  Pc.Equ (Poly.fromVar (getMINmarker isMINs f), Poly.zero)
and getMINmarker isMINs f =
  List.assoc f isMINs

and getLhsMin isMINs rule =
  getIsMIN isMINs (Term.getFun (Rule.getLeft rule))
and getLhsNotMin isMINs rule =
  getIsNotMIN isMINs (Term.getFun (Rule.getLeft rule))
and getRhsMin isMINs rule =
  getIsMIN isMINs (Term.getFun (Rule.getRight rule))
and getRhsNotMin isMINs rule =
  getIsNotMIN isMINs (Term.getFun (Rule.getRight rule))

and addNeitherMin isMINs weakcond rule =
  (getLhsNotMin isMINs rule)::(getRhsNotMin isMINs rule)::weakcond

and addLhsNotMin isMINs boundcond rule =
  (getLhsNotMin isMINs rule)::boundcond

and create_is_mins trs =
  let funs = Utils.remdup (List.flatten (List.map (fun rule -> (Rule.getFuns rule)) trs)) in
    let map = List.map create_is_min funs in
      (map, List.map snd map)
and create_is_min f =
  (f, f ^ "_isMIN")

and getMinRestrictions isMINsVars =
  List.flatten (List.map getZeroOrOne isMINsVars)
and getZeroOrOne v =
  let vP = Poly.fromVar v in
    [Pc.Leq (Poly.zero, vP); Pc.Leq (vP, Poly.one)]

and getMinImplications isMINs abs =
  match isMINs with
    | [] -> []
    | (f, f_isMIN)::rest -> let f_pol = List.assoc f abs in
                              (getMinImplicationsOne f_isMIN f_pol)::(getMinImplications rest abs)
and getMinImplicationsOne f_isMIN f_pol =
  (getZero f_isMIN, List.map getZero (Polo.getParamsOne ("", f_pol)))
and getZero v =
  Pc.Equ (Poly.fromVar v, Poly.zero)

(* create concrete polo *)
and get_concrete_poly abs isMINs model =
  match abs with
    | [] -> []
    | (f, pol)::popo -> if (isMINs = []) || (isNonMIN isMINs model f) then
                          (f, Some (Polo.get_concrete_poly_one pol model))::(get_concrete_poly popo isMINs model)
                        else
                          (f, None)::(get_concrete_poly popo isMINs model)
and isNonMIN isMINs model f =
  let isMINvar = getMINmarker isMINs f in
    Poly.eq_big_int Big_int.zero_big_int (List.assoc isMINvar model)

and getS4SizeComplexities tgraph ctrsobl =
  let rec removeRulesWithUnknownPreds tgraph ctrsobl unknowns =
    let rec removeOneRuleWithUnknownPreds tgraph ctrsobl x unknowns accu =
      let hasUnknownPred tgraph ctrsobl r unknowns =
        let preds = TGraph.getPreds tgraph [r] in
        let otherPreds = Utils.notInP Rule.equal unknowns preds in
        List.exists (CTRSObl.hasUnknownComplexity ctrsobl) otherPreds
      in

      match x with
      | [] -> accu
      | r::rest -> 
        if hasUnknownPred tgraph ctrsobl r unknowns then
          accu @ rest
        else
          removeOneRuleWithUnknownPreds tgraph ctrsobl rest unknowns (accu @ [r])
    in
    let oldsize = List.length unknowns
    and tmp = removeOneRuleWithUnknownPreds tgraph ctrsobl unknowns unknowns [] in
    if oldsize = (List.length tmp) then
      unknowns
    else
      removeRulesWithUnknownPreds tgraph ctrsobl tmp
  in
  let unknowns = CTRSObl.getUnknownComplexityRules ctrsobl in
  removeRulesWithUnknownPreds tgraph ctrsobl unknowns

and getC useSizeComplexities tgraph conc ctrsobl toOrient globalSizeComplexities =
  let vars = CTRS.getVars ctrsobl.ctrs in
  if useSizeComplexities then
    let funs_toOrient = Utils.remdup (List.map (fun rule -> Term.getFun (Rule.getLeft rule)) toOrient) in
    let pre_toOrient = Utils.notInP Rule.equal toOrient (TGraph.getPreds tgraph toOrient) in
    Complexity.listAdd (List.map (getTerm conc ctrsobl pre_toOrient globalSizeComplexities vars) funs_toOrient)
  else
    let pol_start = List.assoc ctrsobl.ctrs.startFun conc in
    let varBindings = List.mapi (fun i v -> ("X_" ^ (string_of_int (i + 1)), Expexp.fromVar v)) vars in
    Complexity.P (Expexp.abs (Expexp.instantiate (Expexp.fromPoly (Utils.unboxOption pol_start)) varBindings))
and getTerm conc ctrsobl pre_toOrient globalSizeComplexities vars f =
  let getTermForPreRule pol_f globalSizeComplexities vars prerule =
    let k = CTRSObl.getComplexity ctrsobl prerule in
    let csmap = GSC.extractSizeMapForRule globalSizeComplexities prerule 0 vars in
    let applied = Complexity.apply (Expexp.abs (Expexp.fromPoly (Utils.unboxOption pol_f))) csmap in
    Complexity.mult k applied
  in
  let t_f = List.filter (fun rule -> (Term.getFun (Rule.getRight rule)) = f) pre_toOrient in
  let pol_f = List.assoc f conc in
  Complexity.listAdd (List.map (getTermForPreRule pol_f globalSizeComplexities vars) t_f)


and isStrict strictVar model =
  try
    Pc.isTrue strictVar model
  with
  | Not_found -> false
and annotate ctrsobl s strict model d =
  let newComplexity =
    List.fold_left 
      (fun newComplexity (rule, strictVar) -> 
        if isStrict strictVar model && CTRSObl.hasUnknownComplexity ctrsobl rule then 
          RuleMap.add rule d newComplexity
        else
          newComplexity)
      ctrsobl.complexity
      (List.combine s strict)
  in
  { ctrs = ctrsobl.ctrs ; cost = ctrsobl.cost ; complexity = newComplexity ; leafCost = ctrsobl.leafCost }

and annotateMinimal ctrsobl s bounds stricts rhsmins model d =
  let isStrictMinimal bound strict rhsminimal model =
    (isStrict bound model) && ((isStrict strict model) || (isStrict rhsminimal model))
  in
  let newComplexity =
    List.fold_left 
      (fun newComplexity (rule, boundVar, strictVar, rhsMinVar) -> 
        if isStrictMinimal boundVar strictVar rhsMinVar model && CTRSObl.hasUnknownComplexity ctrsobl rule then 
          RuleMap.add rule d newComplexity
        else
          newComplexity)
      ctrsobl.complexity
      (Utils.combine4 s bounds stricts rhsmins)
  in
  { ctrs = ctrsobl.ctrs ; cost = ctrsobl.cost ; complexity = newComplexity ; leafCost = ctrsobl.leafCost }


and getProof oldctrsobl newctrsobl pol useSizeComplexities sizeComplexities toOrient ini outi =
  let newlybound = List.filter (fun rule -> not (CTRSObl.hasUnknownComplexity newctrsobl rule)) (CTRSObl.getUnknownComplexityRules oldctrsobl) in
  let moreThanOne = (List.length newlybound) <> 1 in
  "A polynomial rank function with\n" ^
    (pol_to_string pol) ^ "\n" ^
    (if useSizeComplexities then ("and size complexities\n" ^ (GSC.printSizeComplexities newctrsobl sizeComplexities) ^ "\n") else "") ^
    "orients " ^ (printOrientedRules useSizeComplexities toOrient) ^ "weakly and the " ^ (if moreThanOne then "transitions" else "transition") ^ "\n" ^
    (Rule.listToStringPrefix "\t" newlybound) ^ "\n" ^
    "strictly and produces the following problem:\n" ^
    (CTRSObl.toStringNumber newctrsobl outi)
and printOrientedRules useSizeComplexities toOrient =
  if useSizeComplexities then
    "the " ^ (if (List.length toOrient) <> 1 then "transitions" else "transition") ^ "\n" ^
      (Trs.toStringPrefix "\t" toOrient) ^ "\n"
  else "all transitions "
and pol_to_string pol =
  String.concat "\n" (List.map pol_to_string_one pol)
and pol_to_string_one (f, pol_opt) =
  "\tPol(" ^ f ^ ") = " ^ (if pol_opt = None then "-infty" else (Poly.toString (rename (Utils.unboxOption pol_opt))))
and rename pol =
  let vars = Poly.getVars pol in
  let mapping = List.map (fun x_i -> (x_i, Poly.fromVar ("V" ^ (String.sub x_i 1 ((String.length x_i) - 1))))) vars in
  Poly.instantiate pol mapping
