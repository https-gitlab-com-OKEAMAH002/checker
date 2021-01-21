type t =
  { (* TODO: Perhaps maintain 1/q instead of q? TBD *)
    q : FixedPoint.t; (* 1/kit, really *)
    index: Ligo.tez;
    protected_index: Ligo.tez;
    target: FixedPoint.t;
    drift_derivative: FixedPoint.t;
    drift: FixedPoint.t;
    burrow_fee_index: FixedPoint.t;
    imbalance_index: FixedPoint.t;
    (* TODO: Test that this value does not drift too far from the real value
     * (the total amount of kit needed to close all burrows). Errors of a few
     * percents per year are NOT acceptable. Errors of 0.1% or so per year
     * would be tolerable. *)
    outstanding_kit: Kit.t;
    circulating_kit: Kit.t;
    last_touched: Ligo.timestamp;
  }
[@@deriving show]

(** Initial state of the parameters. TODO: Contents TBD. *)
let initial_parameters : t =
  { q = FixedPoint.one;
    index = Ligo.tez_from_mutez_literal 1_000_000;
    protected_index = Ligo.tez_from_mutez_literal 1_000_000;
    target = FixedPoint.one;
    drift = FixedPoint.zero;
    drift_derivative = FixedPoint.zero;
    burrow_fee_index = FixedPoint.one;
    imbalance_index = FixedPoint.one;
    (* Cannot be zero because then it stays
     * zero forever; only multiplications occur. *)
    outstanding_kit = Kit.of_mukit (Ligo.int_from_literal 1);
    circulating_kit = Kit.of_mukit (Ligo.int_from_literal 1);
    last_touched = !Ligo.Tezos.now;
  }

(* tez. To get tez/kit must multiply with q. *)
let tz_minting (p: t) : Ligo.tez = Common.tez_max p.index p.protected_index

(* tez. To get tez/kit must multiply with q. *)
let tz_liquidation (p: t) : Ligo.tez = Common.tez_min p.index p.protected_index

(** Current minting price (tez/kit). *)
let minting_price (p: t) : Ratio.t =
  Ratio.mul (FixedPoint.to_ratio p.q) (Ratio.of_tez (tz_minting p))

(** Current liquidation price (tez/kit). *)
let liquidation_price (p: t) : Ratio.t =
  Ratio.mul (FixedPoint.to_ratio p.q) (Ratio.of_tez (tz_liquidation p))

let qexp amount = Ratio.add Ratio.one amount

let clamp (v: Ratio.t) (lower: Ratio.t) (upper: Ratio.t) : 'a =
  assert (Ratio.leq lower upper);
  Ratio.min upper (Ratio.max v lower)

(** Given the amount of kit necessary to close all existing burrows
  * (burrowed) and the amount of kit that are currently in circulation,
  * compute the current imbalance adjustment (can be either a fee or a
  * bonus).
  *
  * If we call "burrowed" the total amount of kit necessary to close all
  * existing burrows, and "circulating" the total amount of kit in circulation,
  * then the imbalance fee/bonus is calculated as follows (per year):
  *
  *   min((burrowed - circulating) / burrowed,   0.20) * (1/0.20) * 0.05 , if burrowed >= circulating
  *   max((burrowed - circulating) / burrowed, - 0.20) * (1/0.20) * 0.05 , otherwise
  *
  * or, equivalently,
  *
  *   min(5 * (burrowed - circulating),   burrowed) / (20 * burrowed) , if burrowed >= circulating
  *   max(5 * (burrowed - circulating), - burrowed) / (20 * burrowed) , otherwise
  *
  * Edge cases:
  * - burrowed = 0, circulating = 0
  *     The imbalance fee/bonus is 0.
  * - burrowed = 0, circulating > 0
  *     Well, burrowed is "infinitely" smaller than circulating so let's
  *     saturate the imbalance to -5 cNp.
  * NOTE: Alternatively: add (universally) 1mukit to the denominator to avoid
  *   doing conditionals and save gas costs. Messes only slightly with the
  *   computations, but can save quite some gas. *)
let compute_imbalance ~(burrowed: Kit.t) ~(circulating: Kit.t) : Ratio.t =
  assert (burrowed >= Kit.zero);
  assert (circulating >= Kit.zero);
  if burrowed = Kit.zero && circulating = Kit.zero then
    Ratio.zero
  else if burrowed = Kit.zero && circulating <> Kit.zero then
    Ratio.make (Ligo.int_from_literal (-5)) (Ligo.int_from_literal 100)
  else if burrowed >= circulating then
    Ratio.div
      (Ratio.min (Ratio.mul (Ratio.of_int (Ligo.int_from_literal 5)) (Kit.to_ratio (Kit.sub burrowed circulating))) (          (Kit.to_ratio burrowed)))
      (Ratio.mul (Ratio.of_int (Ligo.int_from_literal 20)) (Kit.to_ratio burrowed))
  else (* burrowed < circulating *)
    Ratio.div
      (Ratio.max (Ratio.mul (Ratio.of_int (Ligo.int_from_literal 5)) (Kit.to_ratio (Kit.sub burrowed circulating))) (Ratio.neg (Kit.to_ratio burrowed)))
      (Ratio.mul (Ratio.of_int (Ligo.int_from_literal 20)) (Kit.to_ratio burrowed))

(** Compute the current adjustment index. Basically this is the product of
  * the burrow fee index and the imbalance adjustment index. *)
let compute_adjustment_index (p: t) : FixedPoint.t =
  let burrow_fee_index = FixedPoint.to_ratio p.burrow_fee_index in
  let imbalance_index = FixedPoint.to_ratio p.imbalance_index in
  FixedPoint.of_ratio_floor (Ratio.mul burrow_fee_index imbalance_index)

(** Given the current target, calculate the rate of change of the drift (drift
  * derivative). That's how the following calculations came to be:
  *
  *   let X = log (p_t) be the "measure of imbalance". The original doc gave:
  *
  *   d_t' = 0                             if 0       <= |X| < 0.5 cNp
  *   d_t' = sign(X) * 0.01 cNp / day^2    if 0.5 cNp <= |X| <   5 cNp
  *   d_t' = sign(X) * 0.05 cNp / day^2    if   5 cNp <= |X| < infinity
  *
  *   1. Inline the numbers: cNp ~= 1/100, day ~= 24 * 60 * 60 = 86400 seconds
  *
  *   d_t' = 0                             if 0     <= |X| < 0.005
  *   d_t' = sign(X) * 0.0001 / 86400^2    if 0.005 <= |X| < 0.05
  *   d_t' = sign(X) * 0.0005 / 86400^2    if 0.05  <= |X| < infinity
  *
  *   2. Remove absolute values
  *
  *   d_t' =  0                   if -0.005 <  X <  0.005
  *   d_t' = +0.0001 / 86400^2    if +0.005 <= X < +0.05
  *   d_t' = -0.0001 / 86400^2    if -0.005 >= X > -0.05
  *   d_t' = +0.0005 / 86400^2    if +0.05  <= X < +infinity
  *   d_t' = -0.0005 / 86400^2    if -0.05  >= X > -infinity
  *
  *   3. Exponentiate the inequalities
  *
  *   d_t' =  0                   if exp(-0.005) <  p_t < exp(+0.005)
  *   d_t' = +0.0001 / 86400^2    if exp(+0.005) <= p_t < exp(+0.05)
  *   d_t' = -0.0001 / 86400^2    if exp(-0.005) >= p_t > exp(-0.05)
  *   d_t' = +0.0005 / 86400^2    if exp(+0.05)  <= p_t < +infinity
  *   d_t' = -0.0005 / 86400^2    if exp(-0.05)  >= p_t > -infinity
  *
  * I've left these calculations here so that others could double-check them too.
*)
let compute_drift_derivative (target : FixedPoint.t) : FixedPoint.t =
  assert (target > FixedPoint.zero);
  let target = FixedPoint.to_ratio target in
  let target_low_bracket  = Constants.target_low_bracket in
  let target_high_bracket = Constants.target_high_bracket in
  let cnp_001 = FixedPoint.of_ratio_floor (Ratio.make (Ligo.int_from_literal 1) (Ligo.int_from_literal 10000)) in
  let cnp_005 = FixedPoint.of_ratio_floor (Ratio.make (Ligo.int_from_literal 5) (Ligo.int_from_literal 10000)) in
  let secs_in_a_day = FixedPoint.of_int Constants.seconds_in_a_day in
  match () with
  (* No acceleration (0) *)
  | () when Ratio.lt (qexp (Ratio.neg target_low_bracket)) target && Ratio.lt target (qexp target_low_bracket) -> FixedPoint.zero
  (* Low acceleration (-/+) *)
  | () when Ratio.lt (qexp (Ratio.neg target_high_bracket)) target && Ratio.leq target (qexp (Ratio.neg target_low_bracket))
    -> FixedPoint.neg (FixedPoint.div cnp_001 (FixedPoint.pow secs_in_a_day (Ligo.nat_from_literal 2)))
  | () when Ratio.gt (qexp (          target_high_bracket)) target && Ratio.geq target (qexp (          target_low_bracket))
    ->                (FixedPoint.div cnp_001 (FixedPoint.pow secs_in_a_day (Ligo.nat_from_literal 2)))
  (* High acceleration (-/+) *)
  | () when Ratio.leq target (qexp (Ratio.neg target_high_bracket)) -> FixedPoint.neg (FixedPoint.div cnp_005 (FixedPoint.pow secs_in_a_day (Ligo.nat_from_literal 2)))
  | () when Ratio.geq target (qexp (          target_high_bracket)) ->                (FixedPoint.div cnp_005 (FixedPoint.pow secs_in_a_day (Ligo.nat_from_literal 2)))
  | _ -> (failwith "impossible" : FixedPoint.t)

(** Update the checker's parameters, given (a) the current timestamp
  * (Tezos.now), (b) the current index (the median of the oracles right now),
  * and (c) the current price of kit in tez, as given by the uniswap
  * sub-contract. *)
let touch
    (current_index: Ligo.tez)
    (current_kit_in_tez: Ratio.t)
    (parameters: t)
  : Kit.t * t =
  let duration_in_seconds =
    Ratio.of_int (* NOTE: can it be negative? Does the protocol ensure this? *)
    @@ Ligo.sub_timestamp_timestamp !Ligo.Tezos.now parameters.last_touched
  in

  let current_protected_index =
    let upper_lim = qexp (Ratio.mul           (Constants.protected_index_epsilon) duration_in_seconds) in
    let lower_lim = qexp (Ratio.mul (Ratio.neg Constants.protected_index_epsilon) duration_in_seconds) in

    Ratio.to_tez_floor
      (Ratio.mul
         (Ratio.of_tez parameters.protected_index)
         (clamp
            (Ratio.make (Common.tez_to_mutez current_index) (Common.tez_to_mutez parameters.protected_index))
            lower_lim
            upper_lim
         )
      ) in
  let current_drift_derivative =
    compute_drift_derivative parameters.target in
  let current_drift =
    FixedPoint.of_ratio_floor
      (Ratio.add
         (FixedPoint.to_ratio parameters.drift)
         (Ratio.mul
            (Ratio.make (Ligo.int_from_literal 1) (Ligo.int_from_literal 2))
            (Ratio.mul
               (FixedPoint.to_ratio (FixedPoint.add parameters.drift_derivative current_drift_derivative))
               duration_in_seconds
            )
         )
      ) in
  let current_q =
    FixedPoint.of_ratio_floor
      (Ratio.mul
         (FixedPoint.to_ratio parameters.q)
         (qexp
            (Ratio.mul
               (Ratio.add
                  (FixedPoint.to_ratio parameters.drift)
                  (Ratio.mul
                     (Ratio.make (Ligo.int_from_literal 1) (Ligo.int_from_literal 6))
                     (Ratio.mul
                        (Ratio.add
                           (Ratio.mul
                              (Ratio.of_int (Ligo.int_from_literal 2))
                              (FixedPoint.to_ratio parameters.drift_derivative)
                           )
                           (FixedPoint.to_ratio current_drift_derivative)
                        )
                        duration_in_seconds
                     )
                  )
               )
               duration_in_seconds
            )
         )
      ) in

  let current_target =
    FixedPoint.of_ratio_floor
      (Ratio.div
         (Ratio.mul
            (FixedPoint.to_ratio current_q)
            (Ratio.of_tez current_index)
         )
         current_kit_in_tez
      ) in
  (* Update the indices *)
  let current_burrow_fee_index =
    (* NOTE: This formula means that burrow_fee_index is ever-increasing. *)
    FixedPoint.of_ratio_floor
      (Ratio.mul
         (FixedPoint.to_ratio parameters.burrow_fee_index)
         (Ratio.add
            Ratio.one
            (Ratio.div
               (Ratio.mul Constants.burrow_fee_percentage duration_in_seconds)
               (Ratio.of_int Constants.seconds_in_a_year)
            )
         )
      ) in

  let current_imbalance_index =
    let imbalance_rate =
      compute_imbalance
        ~burrowed:parameters.outstanding_kit
        ~circulating:parameters.circulating_kit in
    FixedPoint.of_ratio_floor
      (Ratio.mul
         (FixedPoint.to_ratio parameters.imbalance_index)
         (Ratio.add
            Ratio.one
            (Ratio.div
               (Ratio.mul imbalance_rate duration_in_seconds)
               (Ratio.of_int Constants.seconds_in_a_year)
            )
         )
      ) in

  let outstanding_with_fees =
    Kit.of_ratio_floor
      (Ratio.div
         (Ratio.mul
            (Kit.to_ratio parameters.outstanding_kit)
            (FixedPoint.to_ratio current_burrow_fee_index)
         )
         (FixedPoint.to_ratio parameters.burrow_fee_index)
      ) in

  let accrual_to_uniswap = Kit.sub outstanding_with_fees parameters.outstanding_kit in

  let current_outstanding_kit =
    Kit.of_ratio_floor
      (Ratio.div
         (Ratio.mul
            (Kit.to_ratio outstanding_with_fees)
            (FixedPoint.to_ratio current_imbalance_index)
         )
         (FixedPoint.to_ratio parameters.imbalance_index)
      ) in

  let current_circulating_kit = Kit.add parameters.circulating_kit accrual_to_uniswap in

  ( accrual_to_uniswap
  , {
    index = current_index;
    protected_index = current_protected_index;
    target = current_target;
    drift = current_drift;
    drift_derivative = current_drift_derivative;
    q = current_q;
    burrow_fee_index = current_burrow_fee_index;
    imbalance_index = current_imbalance_index;
    outstanding_kit = current_outstanding_kit;
    circulating_kit = current_circulating_kit;
    last_touched = !Ligo.Tezos.now;
  }
  )

(** Add some kit to the total amount of kit in circulation. *)
let add_circulating_kit (parameters: t) (kit: Kit.t) : t =
  assert (kit >= Kit.zero);
  { parameters with circulating_kit = Kit.add parameters.circulating_kit kit; }

(** Remove some kit from the total amount of kit in circulation. *)
let remove_circulating_kit (parameters: t) (kit: Kit.t) : t =
  assert (kit >= Kit.zero);
  assert (parameters.circulating_kit >= kit);
  { parameters with circulating_kit = Kit.sub parameters.circulating_kit kit; }

(** Add some kit to the total amount of kit required to close all burrows. *)
let add_outstanding_kit (parameters: t) (kit: Kit.t) : t =
  assert (kit >= Kit.zero);
  { parameters with outstanding_kit = Kit.add parameters.outstanding_kit kit; }

(** Remove some kit from the total amount of kit required to close all burrows. *)
let remove_outstanding_kit (parameters: t) (kit: Kit.t) : t =
  assert (kit >= Kit.zero);
  assert (parameters.outstanding_kit >= kit);
  { parameters with outstanding_kit = Kit.sub parameters.outstanding_kit kit; }
