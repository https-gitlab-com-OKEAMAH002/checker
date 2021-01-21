(* Tezos utilities *)

let level_to_cycle t = Ligo.div_nat_nat t (Ligo.nat_from_literal "4096n")

(* OPERATIONS ON int *)
let int_min x y = if Ligo.leq_int_int x y then x else y
let int_max x y = if Ligo.geq_int_int x y then x else y

let neg_int x = Ligo.mul_int_int x (Ligo.int_from_literal "-1")
let abs_int x = Ligo.int (Ligo.abs x)

let pow_int_nat x n =
  (* Note that ligo is not happy with nested lets. Take out when ready, but
   * keep internal for now. *)
  let rec pow_rec y x n =
    if Ligo.eq_nat_nat n (Ligo.nat_from_literal "0n") then
      y
    else if Ligo.eq_nat_nat n (Ligo.nat_from_literal "1n") then
      Ligo.mul_int_int x y
    else
      match Ligo.ediv_nat_nat n (Ligo.nat_from_literal "2n") with
      | None -> (failwith "impossible" : Ligo.int)
      | Some (quot, rem) ->
        if Ligo.eq_nat_nat rem (Ligo.nat_from_literal "0n") then
          pow_rec y (Ligo.mul_int_int x x) quot
        else
          pow_rec (Ligo.mul_int_int x y) (Ligo.mul_int_int x x) quot
  in
  pow_rec (Ligo.int_from_literal "1") x n

let cdiv_int_int x y =
  match Ligo.ediv_int_int x y with
  | None -> (failwith "Ligo.cdiv_int_int: zero denominator" : Ligo.int)
  | Some (quot, rem) ->
    if Ligo.eq_nat_nat rem (Ligo.nat_from_literal "0n") then
      quot
    else if Ligo.lt_int_int y (Ligo.int_from_literal "0") then
      quot
    else
      Ligo.add_int_int quot (Ligo.int_from_literal "1")

let fdiv_int_int x y =
  match Ligo.ediv_int_int x y with
  | None -> (failwith "Ligo.fdiv_int_int: zero denominator" : Ligo.int)
  | Some (quot, rem) ->
    if Ligo.eq_nat_nat rem (Ligo.nat_from_literal "0n") then
      quot
    else if Ligo.gt_int_int y (Ligo.int_from_literal "0") then
      quot
    else
      Ligo.sub_int_int quot (Ligo.int_from_literal "1")

(* OPERATIONS ON tez *)
let tez_min x y = if Ligo.leq_tez_tez x y then x else y
let tez_max x y = if Ligo.geq_tez_tez x y then x else y
let tez_to_mutez x = Ligo.int (Ligo.div_tez_tez x (Ligo.tez_from_literal "1mutez"))
