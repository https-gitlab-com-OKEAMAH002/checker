type bid_ticket

type t

type Error.error +=
  | BidTooLow
  | BidTicketExpired
  | CannotReclaimLeadingBid
  | CannotReclaimWinningBid
  | NotAWinningBid

val empty : Tezos.t -> t

val touch : t -> Tezos.t -> t

(** Retrieve the delegate for this cycle *)
val delegate : t -> Ligo.address option

val cycle : t -> int

val winning_amount : t -> Ligo.tez option

(* TODO: can we bid to nominate someone else as a baker? *)
val place_bid : t -> Tezos.t -> sender:Ligo.address -> amount:Ligo.tez -> (bid_ticket * t, Error.error) result

val claim_win : t -> Tezos.t -> bid_ticket:bid_ticket
  -> (t, Error.error) result

val reclaim_bid : t -> Tezos.t -> bid_ticket:bid_ticket -> (Ligo.tez * t, Error.error) result

val show : t -> string
val pp : Format.formatter -> t -> unit
