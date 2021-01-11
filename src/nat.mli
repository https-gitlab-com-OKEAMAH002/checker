type t (* INVARIANT: NON-NEGATIVE *)

val show : t -> string
val pp : Format.formatter -> t -> unit

val compare : t -> t -> int
val ( + ) : t -> t -> t
val sub : t -> t -> Z.t

val zero : t
val one : t

val to_int : t -> Z.t        (* In LIGO: int *)
val abs    : Z.t -> t        (* In LIGO: abs *)
val of_int : Z.t -> t option (* In LIGO: Michelson.is_nat *)

val to_q : t -> Q.t (* (TODO: Use Ratio.t, eventually) Always succeeds. *)
val of_q_floor : Q.t -> t (* (TODO: Use Ratio.t, eventually) May fail, of course. Rounds down. *)
val of_q_ceil : Q.t -> t  (* (TODO: Use Ratio.t, eventually) May fail, of course. Rounds up *)
