open OUnit2

type tz = Tez.t [@@deriving show]
type fp = FixedPoint.t [@@deriving show]

let suite =
  "TezTests" >::: [
    "tez arithmetic" >::
    (fun _ ->
       assert_equal ~printer:show_tz
         (Tez.of_mutez 8_000_000)
         Tez.(of_mutez 5_000_000 + of_mutez 3_000_000);
       assert_equal ~printer:show_tz
         (Tez.of_mutez 2_000_000)
         Tez.(of_mutez 5_000_000 - of_mutez 3_000_000);
       assert_equal
         ~printer:show_tz
         (Tez.of_mutez 5_000_000)
         (max (Tez.of_mutez 5_000_000) (Tez.of_mutez 3_000_000));
       assert_equal
         ~printer:(fun x -> x)
         "50309951mutez"
         (show_tz (Tez.of_mutez 50_309_951));
    )
  ]
