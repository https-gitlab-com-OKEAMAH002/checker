open Burrow
open OUnit2

let property_test_count = 100
let qcheck_to_ounit t = OUnit.ounit2_of_ounit1 @@ QCheck_ounit.to_ounit_test t

(* Create an arbitrary burrow state, given the set of checker's parameters (NB:
 * most values are fixed). NOTE: Given that to get a "Close" we need the
 * collateral to be less than a tez, getting a "Close" for what
 * arbitrary_burrow generates is not very likely to happen. Write a smarter
 * generator for these cases. *)
let arbitrary_burrow (params: Parameters.t) =
  QCheck.map
    (fun (tez, kit) ->
       Burrow.make_for_test
         ~permission_version:0
         ~allow_all_tez_deposits:false
         ~allow_all_kit_burnings:false
         ~delegate:None
         ~active:true
         ~collateral:tez
         ~outstanding_kit:kit
         ~excess_kit:Kit.zero
         ~adjustment_index:(Parameters.compute_adjustment_index params)
         ~collateral_at_auction:Tez.zero
         ~last_touched:(Timestamp.of_seconds 0)
         ~liquidation_slices:None
    )
    (QCheck.pair TestArbitrary.arb_tez TestArbitrary.arb_kit)

(*
Properties we expect to hold
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
General
* is_liquidatable ==> is_overburrowed (not the other way around)
* No interaction with the burrow has any effect if it's inactive.
* Liquidation of an active burrow with collateral < creation_deposit should "close" it
*)

let params : Parameters.t =
  { q = FixedPoint.of_q_floor (Q.of_string "1015/1000");
    index = Tez.of_mutez 320_000;
    protected_index = Tez.of_mutez 360_000;
    target = FixedPoint.of_q_floor (Q.of_string "108/100");
    drift = FixedPoint.zero;
    drift' = FixedPoint.zero;
    burrow_fee_index = FixedPoint.one;
    imbalance_index = FixedPoint.one;
    outstanding_kit = Kit.one;
    circulating_kit = Kit.one;
    last_touched = Timestamp.of_seconds 0;
  }

(* If a liquidation was deemed Partial:
 * - is_liquidatable is true for the given burrow
 * - is_optimistically_overburrowed is false for the resulting burrow
*)
let properties_of_partial_liquidation burrow details =
  assert_bool
    "partial liquidation means liquidatable input burrow"
    (Burrow.is_liquidatable params burrow);
  assert_bool
    "partial liquidation means non-optimistically-overburrowed output burrow"
    (not (Burrow.is_optimistically_overburrowed params details.burrow_state))

(* If a liquidation was deemed Complete:
 * - is_liquidatable is true for the given burrow
 * - is_optimistically_overburrowed is true for the resulting burrow
 * - the resulting burrow has no collateral
*)
let properties_of_complete_liquidation burrow details =
  assert_bool
    "complete liquidation means liquidatable input burrow"
    (Burrow.is_liquidatable params burrow);
  assert_bool
    "complete liquidation means optimistically-overburrowed output burrow"
    (Burrow.is_optimistically_overburrowed params details.burrow_state);
  assert_bool
    "complete liquidation means no collateral in the output burrow"
    (Burrow.collateral details.burrow_state = Tez.zero)

(* If a liquidation was deemed Close:
 * - is_liquidatable is true for the given burrow
 * - the resulting burrow has no collateral
 * - the resulting burrow is inactive
*)
let properties_of_close_liquidation burrow details =
  assert_bool
    "close liquidation means liquidatable input burrow"
    (Burrow.is_liquidatable params burrow);
  assert_bool
    "close liquidation means no collateral in the output burrow"
    (Burrow.collateral details.burrow_state = Tez.zero);
  assert_bool
    "close liquidation means inactive output burrow"
    (not (Burrow.active details.burrow_state))

let test_general_liquidation_properties =
  qcheck_to_ounit
  @@ QCheck.Test.make
    ~name:"test_general_liquidation_properties"
    ~count:property_test_count
    (arbitrary_burrow params)
  @@ fun burrow ->
    match Burrow.request_liquidation params burrow with
      (* If a liquidation was deemed Unnecessary then is_liquidatable must be
       * false for the input burrow. *)
    | Unnecessary ->
      assert_bool
        "unnecessary liquidation means non-liquidatable input burrow"
        (not (Burrow.is_liquidatable params burrow));
      true
    | Partial details ->
      properties_of_partial_liquidation burrow details; true
    | Complete details ->
      properties_of_complete_liquidation burrow details; true
      (* NOTE: according to my calculations, this almost never
       * fires; we should add a separate test for these cases. *)
    | Close details ->
      properties_of_close_liquidation burrow details; true

let initial_burrow =
  Burrow.make_for_test
    ~permission_version:0
    ~allow_all_tez_deposits:false
    ~allow_all_kit_burnings:false
    ~delegate:None
    ~active:true
    ~collateral:(Tez.of_mutez 10_000_000)
    ~outstanding_kit:(Kit.of_mukit (Z.of_int 20_000_000))
    ~excess_kit:Kit.zero
    ~adjustment_index:(Parameters.compute_adjustment_index params)
    ~collateral_at_auction:Tez.zero
    ~last_touched:(Timestamp.of_seconds 0)
    ~liquidation_slices:None

let partial_liquidation_unit_test =
  "partial_liquidation_unit_test" >:: fun _ ->
    let burrow = initial_burrow in

    assert_bool "is overburrowed" (Burrow.is_overburrowed params burrow);
    assert_bool "is optimistically overburrowed" (Burrow.is_optimistically_overburrowed params burrow);
    assert_bool "is liquidatable" (Burrow.is_liquidatable params burrow);

    let liquidation_result = Burrow.request_liquidation params burrow in

    assert_equal
      (Partial
         { liquidation_reward = Tez.(Constants.creation_deposit + Tez.of_mutez 9_999);
           tez_to_auction = Tez.of_mutez 7_142_471;
           expected_kit = Kit.of_mukit (Z.of_int 17_592_294);
           min_kit_for_unwarranted = Kit.of_mukit (Z.of_int 27_141_390);
           burrow_state =
             Burrow.make_for_test
               ~permission_version:0
               ~allow_all_tez_deposits:false
               ~allow_all_kit_burnings:false
               ~delegate:None
               ~active:true
               ~collateral:(Tez.of_mutez 1_847_530)
               ~outstanding_kit:(Kit.of_mukit (Z.of_int 20_000_000))
               ~excess_kit:Kit.zero
               ~adjustment_index:(Parameters.compute_adjustment_index params)
               ~collateral_at_auction:(Tez.of_mutez 7_142_471)
               ~last_touched:(Timestamp.of_seconds 0)
               ~liquidation_slices:None
         }
      )
      liquidation_result
      ~printer:Burrow.show_liquidation_result;

    match liquidation_result with
    | Unnecessary | Complete _ | Close _ -> failwith "impossible"
    | Partial details ->
      assert_bool "is overburrowed" (Burrow.is_overburrowed params details.burrow_state);
      assert_bool "is not optimistically overburrowed" (not (Burrow.is_optimistically_overburrowed params details.burrow_state));
      assert_bool "is not liquidatable" (not (Burrow.is_liquidatable params details.burrow_state));
      assert_bool "is active" (Burrow.active details.burrow_state)

let unwarranted_liquidation_unit_test =
  "unwarranted_liquidation_unit_test" >:: fun _ ->
    let burrow =
      Burrow.make_for_test
        ~permission_version:0
        ~allow_all_tez_deposits:false
        ~allow_all_kit_burnings:false
        ~delegate:None
        ~active:true
        ~collateral:(Tez.of_mutez 10_000_000)
        ~outstanding_kit:(Kit.of_mukit (Z.of_int 10_000_000))
        ~excess_kit:Kit.zero
        ~adjustment_index:(Parameters.compute_adjustment_index params)
        ~collateral_at_auction:Tez.zero
        ~last_touched:(Timestamp.of_seconds 0)
        ~liquidation_slices:None
    in

    assert_bool "is not overburrowed" (not (Burrow.is_overburrowed params burrow));
    assert_bool "is not optimistically overburrowed" (not (Burrow.is_optimistically_overburrowed params burrow));
    assert_bool "is not liquidatable" (not (Burrow.is_liquidatable params burrow));

    let liquidation_result = Burrow.request_liquidation params burrow in
    assert_equal Unnecessary liquidation_result ~printer:Burrow.show_liquidation_result

let complete_liquidation_unit_test =
  "complete_liquidation_unit_test" >:: fun _ ->
    let burrow =
      Burrow.make_for_test
        ~permission_version:0
        ~allow_all_tez_deposits:false
        ~allow_all_kit_burnings:false
        ~delegate:None
        ~active:true
        ~collateral:(Tez.of_mutez 10_000_000)
        ~outstanding_kit:(Kit.of_mukit (Z.of_int 100_000_000))
        ~excess_kit:Kit.zero
        ~adjustment_index:(Parameters.compute_adjustment_index params)
        ~collateral_at_auction:Tez.zero
        ~last_touched:(Timestamp.of_seconds 0)
        ~liquidation_slices:None
    in

    assert_bool "is overburrowed" (Burrow.is_overburrowed params burrow);
    assert_bool "is optimistically overburrowed" (Burrow.is_optimistically_overburrowed params burrow);
    assert_bool "is liquidatable" (Burrow.is_liquidatable params burrow);

    let liquidation_result = Burrow.request_liquidation params burrow in

    assert_equal
      (Complete
         { liquidation_reward = Tez.(Constants.creation_deposit + Tez.of_mutez 9_999);
           tez_to_auction = Tez.of_mutez 8_990_001;
           expected_kit = Kit.of_mukit (Z.of_int 22_142_860);
           min_kit_for_unwarranted = Kit.of_mukit (Z.of_int 170_810_019);
           burrow_state =
             Burrow.make_for_test
               ~permission_version:0
               ~allow_all_tez_deposits:false
               ~allow_all_kit_burnings:false
               ~delegate:None
               ~active:true
               ~collateral:Tez.zero
               ~outstanding_kit:(Kit.of_mukit (Z.of_int 100_000_000))
               ~excess_kit:Kit.zero
               ~adjustment_index:(Parameters.compute_adjustment_index params)
               ~collateral_at_auction:(Tez.of_mutez 8_990_001)
               ~last_touched:(Timestamp.of_seconds 0)
               ~liquidation_slices:None
         }
      )
      liquidation_result
      ~printer:Burrow.show_liquidation_result;

    match liquidation_result with
    | Unnecessary | Partial _ | Close _ -> failwith "impossible"
    | Complete details ->
      assert_bool "is overburrowed" (Burrow.is_overburrowed params details.burrow_state);
      assert_bool "is optimistically overburrowed" (Burrow.is_optimistically_overburrowed params details.burrow_state);
      assert_bool "is liquidatable" (Burrow.is_liquidatable params details.burrow_state);
      assert_bool "is active" (Burrow.active details.burrow_state)

let complete_and_close_liquidation_test =
  "complete_and_close_liquidation_test" >:: fun _ ->
    let burrow =
      Burrow.make_for_test
        ~permission_version:0
        ~allow_all_tez_deposits:false
        ~allow_all_kit_burnings:false
        ~delegate:None
        ~active:true
        ~collateral:(Tez.of_mutez 1_000_000)
        ~outstanding_kit:(Kit.of_mukit (Z.of_int 100_000_000))
        ~excess_kit:Kit.zero
        ~adjustment_index:(Parameters.compute_adjustment_index params)
        ~collateral_at_auction:Tez.zero
        ~last_touched:(Timestamp.of_seconds 0)
        ~liquidation_slices:None
    in

    assert_bool "is overburrowed" (Burrow.is_overburrowed params burrow);
    assert_bool "is optimistically overburrowed" (Burrow.is_optimistically_overburrowed params burrow);
    assert_bool "is liquidatable" (Burrow.is_liquidatable params burrow);

    let liquidation_result = Burrow.request_liquidation params burrow in

    assert_equal
      (Close
         { liquidation_reward = Tez.(Constants.creation_deposit + Tez.of_mutez 999);
           tez_to_auction = Tez.of_mutez 999_001;
           expected_kit = Kit.of_mukit (Z.of_int 2_460_594);
           min_kit_for_unwarranted = Kit.of_mukit (Z.of_int 189_810_190);
           burrow_state =
             Burrow.make_for_test
               ~permission_version:0
               ~allow_all_tez_deposits:false
               ~allow_all_kit_burnings:false
               ~delegate:None
               ~active:false
               ~collateral:Tez.zero
               ~outstanding_kit:(Kit.of_mukit (Z.of_int 100_000_000))
               ~excess_kit:Kit.zero
               ~adjustment_index:(Parameters.compute_adjustment_index params)
               ~collateral_at_auction:(Tez.of_mutez 999_001)
               ~last_touched:(Timestamp.of_seconds 0)
               ~liquidation_slices:None
         }
      )
      liquidation_result
      ~printer:Burrow.show_liquidation_result;

    match liquidation_result with
    | Unnecessary | Partial _ | Complete _ -> failwith "impossible"
    | Close details ->
      assert_bool "is overburrowed" (Burrow.is_overburrowed params details.burrow_state);
      assert_bool "is optimistically overburrowed" (Burrow.is_optimistically_overburrowed params details.burrow_state);
      assert_bool "is not liquidatable" (not (Burrow.is_liquidatable params details.burrow_state));
      assert_bool "is inactive" (not (Burrow.active details.burrow_state))

let suite =
  "LiquidationTests" >::: [
    partial_liquidation_unit_test;
    unwarranted_liquidation_unit_test;
    complete_liquidation_unit_test;
    complete_and_close_liquidation_test;

    (* General, property-based random tests *)
    test_general_liquidation_properties;
  ]
