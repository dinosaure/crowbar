(*

  Generators in crowbar parse test inputs from arbitrary bitstrings,
  building a data structure ('a sample) that represents the test input
  as a tree, so that it can be easily mutated.

  This file contains the definition of generators and samples, basic
  generator combinators, and the algorithms for sampling and
  mutation. Higher-level generator combinators (e.g. lists) live in
  crowbar.ml, and the main fuzzing loop lives in fuzz.ml.

*)

type 'a printer = 'a Printers.printer

type 'a print_style =
  | PrintDefault
  | PrintValue of 'a printer
  | PrintComponents of (unit printer list -> 'a printer)

type 'a primitive_generator = Bytebuf.t -> 'a

type 'a gen = {
  id : 'a Typed_id.t;

  (* How should this generator be sampled? *)
  strategy : 'a gen_strategy;

  (* How should samples taken from this generator be printed? *)
  printer : 'a print_style;

  (* How large is the smallest value that this generator can make? *)
  small_example_size : int;
}

and 'a gen_strategy =
  | Map : int * ('f, 'a) gens * 'f -> 'a gen_strategy
  | Choose of 'a gen array       (* 1 <= length < 256 *)
  | Unlazy of 'a gen Lazy.t
  | Prim of 'a primitive_generator

(* The type ('func, 'res) gens is a tuple of generators, possibly of
   different types, from which a value of type 'res can be constructed
   using a function of type 'func. *)
and ('func, 'res) gens =
  | [] : ('res, 'res) gens
  | (::) : 'a gen * ('func, 'res) gens -> ('a -> 'func, 'res) gens

type nonrec +'a list = 'a list = [] | (::) of 'a * 'a list

let rec gens_length :
  type k res . (k, res) gens -> int =
  function
  | [] -> 0
  | g :: gs -> 1 + gens_length gs




(* Basic combinators *)

let map gens f =
  (* The small_example_size of `map gens f` is the product of the
     sizes of gens, plus 1, with a check to avoid overflow *)
  let max_small_size = 1000 in
  let rec compute_example_size :
    type k res . int -> (k, res) gens -> int =
    fun acc gens -> match gens with
    | [] -> acc + 1
    | { small_example_size = s; _ } :: gens ->
       if acc < max_small_size && s < max_small_size then
         compute_example_size (acc * s) gens
       else
         max_int in
  { id = Typed_id.fresh ();
    strategy = Map (gens_length gens, gens, f);
    printer = PrintDefault;
    small_example_size = compute_example_size 1 gens }


let const k = map [] k


let choose gens =
  (* To ensure that the all-zeros input generates small test cases,
     we sort the generators by small_example_size *)
  let arr = Array.of_list gens in
  Array.stable_sort 
    (fun g1 g2 -> compare g1.small_example_size g2.small_example_size)
    arr;

  let max_choose = 256 in
  let mk_choose =
    function
    | [| |] ->
       { id = Typed_id.fresh ();
         strategy = Choose [| |];
         printer = PrintDefault;
         small_example_size = max_int }
    | [| g |] ->
       g  (* hobson's optimisation *)
    | arr ->
       assert (Array.length arr <= max_choose);
       { id = Typed_id.fresh ();
         strategy = Choose arr;
         printer = PrintDefault;
         small_example_size = arr.(0).small_example_size } in

  (* The length of `gens` is arbitrary, but the Choose strategy only
     allows up to 256 generators. If there are more than 256, we need
     to divide it into nested chunks of Choose *)

  let rec div_choose arr =
    let len = Array.length arr in
    if len <= max_choose then
      mk_choose arr
    else begin
      let nchunks = (len + max_choose - 1) / max_choose in
      let chunks = Array.init nchunks (fun i ->
        let chunk_start = i * max_choose in
        let chunk_end = min len (chunk_start + max_choose) in
        let chunk = Array.init (chunk_end - chunk_start)
                               (fun j -> arr.(chunk_start + j)) in
        mk_choose chunk) in
      div_choose chunks
    end in
  div_choose arr


let unlazy gen =
  try Lazy.force gen with
  | Lazy.Undefined ->
     (* If this happens, then we're using `unlazy foo` inside the
        definition of foo, to build a recursive generator. This is
        fine, but since we should never follow the recursion when
        trying to generate a small value, we report the small example
        size as max_int *)
     { id = Typed_id.fresh ();    (* FIXME should this be fresh? *)
       strategy = Unlazy gen;
       printer = PrintDefault;
       small_example_size = max_int }


let with_printer pv gen =
  { gen with printer = PrintValue pv }

let with_component_printer pc gen =
  { gen with printer = PrintComponents pc }




(* 
   Samples

   Parsing some input data using a generator results in a sample,
   which is a tree-like data structure that records the boundaries
   between different parts of the testcase.

   The tree is heterogenous, since generators are built out of
   generators with different types. This involves some GADT mangling,
   but not much more than the definition of `gens` above.

*)



type 'a sample = {
  (* the generator from which this sample was taken *)
  generator : 'a gen;
  (* the resulting value *)
  value : 'a;
  (* the length in bytes of the bitstring that generates this value *)
  length : int;
  (* the subtrees of this sample *)
  components : 'a sample_components;
}

and 'res sample_components =
  | SMap : ('f, 'res) sample_tuple * 'f -> 'res sample_components
  | SChoose of int * 'res sample
  | SPrim of Bytebuf.mark * 'res primitive_generator

and ('k, 'res) sample_tuple =
  | TNil : 'res -> ('res, 'res) sample_tuple
  | TCons : 'a sample * ('k, 'res) sample_tuple -> ('a -> 'k, 'res) sample_tuple


let sample_len s = s.length
let sample_val s = s.value


let mk_sample bytebuf generator components =
  match components with
  | SMap (sample_tuple, f) ->
     (* compute length and result value from sample_tuple *)
     let rec go : 
       type k res . res gen -> res sample_components -> int -> (k, res) sample_tuple -> res sample =
       fun generator components length samples -> match samples with
       | TNil value ->
          { generator; value; length; components }
       | TCons (x, sample_tuple) ->
          go generator components (length + x.length) sample_tuple in
     go generator components 0 sample_tuple
  | SChoose (tag, t) ->
     { generator; value = t.value; length = t.length + 1; components }
  | SPrim (mark, p) ->
     let value = p bytebuf in
     { generator; value; components;
       length = Bytebuf.extent_since bytebuf mark }


let rec sample :
  type a . a gen -> Bytebuf.t -> int -> a sample =
  fun gen bytebuf size ->
(*  if bytebuf.pos >= bytebuf.len then
    raise No_more_bytes
    match gen.small_examples with
    | [| |] -> failwith "No small examples for generator!"
    | sm -> sm.(0)
  else if size <= 1 then
    let b = read_byte bytebuf in
    match gen.small_examples with
    | [| |] -> failwith "No small examples for generator!"
    | sm -> sm.(b mod Array.length sm)
  else *)
    match gen.strategy with
    | Map (count, gens, f) ->
       mk_sample bytebuf gen (SMap (sample_gens gens f bytebuf size count, f))
    | Choose gens ->
       let b = Bytebuf.read_byte bytebuf in
       let value = sample gens.(b mod Array.length gens) bytebuf (size - 1) in
       (* FIXME: update? *)
       mk_sample bytebuf gen (SChoose (b, value))
    | Unlazy gen ->
       sample (Lazy.force gen) bytebuf size
    | Prim p ->
       mk_sample bytebuf gen (SPrim (Bytebuf.mark bytebuf, p))

and sample_gens :
  type f res . (f, res) gens -> f -> Bytebuf.t -> int -> int -> (f, res) sample_tuple =
  fun gens f state size count -> match gens with
  | [] ->
     TNil f
  | gen :: gens ->
     let x = sample gen state ((size - 1) / count) in
     let sample_tuple = sample_gens gens (f x.value) state size count in
     TCons (x, sample_tuple)

(*
let mkbuf () =
  let buf = Bytes.make 500 '\000' in
  for i = 0 to Bytes.length buf - 1 do
    Bytes.set buf i (Char.chr (Random.bits () land 0xff));
  done;
  Bytebuf.of_bytes buf
*)

let mkbuf () =
  let buf = Bytes.make 500 '\000' in
  for i = 0 to Bytes.length buf - 1 do
    Bytes.set buf i (Char.chr (Random.bits () land 0xff));
    (* Printf.printf "%02x" (Char.code (Bytes.get buf i)); *)
  done;
  (* Printf.printf "\n%!"; *)
  Bytebuf.of_bytes buf


let rec mutate :
  type a . a sample -> int ref -> Bytebuf.t -> a sample =
  fun s pos bytebuf ->
  match s.components with
  | _ when !pos = 0 ->
     (* found the spot to mutate *)
     pos := -s.length;
     sample s.generator bytebuf s.length
  | _ when !pos < 0 || !pos > s.length ->
     (* this subtree remains untouched *)
     pos := !pos - s.length;
     s
  | SChoose (ch, t) ->
     decr pos;  (* skip tag byte *)
     mk_sample bytebuf s.generator (SChoose (ch, mutate t pos bytebuf))
  | SMap (scases, f) ->
     mk_sample bytebuf s.generator (SMap (mutate_gens scases f pos bytebuf, f))
  | SPrim (mark, p) ->
     (* FIXME *)
     assert false

and mutate_gens :
  type f res . (f, res) sample_tuple -> f -> int ref -> Bytebuf.t -> (f, res) sample_tuple =
  fun scases f pos bytebuf -> match scases with
  | TNil _ ->
     TNil f
  | TCons (subcase, sample_tuple) ->
     let subcase' = mutate subcase pos bytebuf in
     let sample_tuple' = mutate_gens sample_tuple (f subcase'.value) pos bytebuf in
     TCons (subcase', sample_tuple')

let mutate sample pos bytebuf =
  if pos < 0 || pos > sample.length then
    raise (Invalid_argument "Gen.mutate: invalid position");
  mutate sample (ref pos) bytebuf


let rec serialize_into :
  type a . a sample -> Bytebuf.t -> unit =
  fun s b ->
  assert (b.len - b.pos >= s.length);
  match s.components with
  | SMap (subcases, f) ->
     serialize_tuple_into subcases b
  | SChoose (tag, tc) ->
     Bytebuf.write_char b (Char.chr tag);
     serialize_into tc b
  | SPrim (mark, p) ->
     Bytebuf.copy_since_mark b mark s.length

and serialize_tuple_into :
  type k res . (k, res) sample_tuple -> Bytebuf.t -> unit =
  fun ss b -> match ss with
  | TNil _ -> ()
  | TCons (s, rest) -> serialize_into s b; serialize_tuple_into rest b




let rec print : type a . a sample printer = fun ppf s ->
  let open Printers in
  match s.generator.printer with
  | PrintDefault ->
     begin match s.components with
     | SMap (comps, _) ->
        pp_list pp_printer ppf (print_tuple comps)
     | SChoose (k, s) ->
        pp ppf "#%d %a" k print s
     | SPrim _ ->
        pp ppf "_"
     end
  | PrintValue pv ->
     pv ppf s.value
  | PrintComponents pcomps ->
     let comps =
       match s.components with
       | SMap (comps, _) -> print_tuple comps
       | SChoose (_, s) -> [fun ppf () -> print ppf s]
       | SPrim _ -> [] in
     pcomps comps ppf s.value

and print_tuple : type k res . (k, res) sample_tuple -> unit printer list = function
  | TNil _ -> []
  | TCons (s, rest) -> (fun ppf () -> print ppf s) :: print_tuple rest
  





module Fragment_Pool : sig
  type t
  val add : t -> 'a sample -> unit
  val sample : t -> 'a gen -> 'a sample (* may raise Not_found *)
end = struct
  type fraglist = Fraglist : {
    gen_id : 'a Typed_id.t;
    mutable len : int;
    mutable samples : 'a sample array
  } -> fraglist
  module H = Hashtbl.Make (struct type t = int let hash x = x let equal (x : int) (y : int) = (x = y) end)
  type t = fraglist H.t

  let add tbl (type a) (s : a sample) =
    let id = s.generator.id in
    match H.find tbl (Typed_id.to_int id) with
    | exception Not_found ->
       H.add tbl (Typed_id.to_int id)
         (Fraglist { gen_id = id; len = 1; samples = Array.make 8 s })
    | Fraglist fl ->
       if fl.len = Array.length fl.samples then begin
         let bigger = Array.make (fl.len * 2) fl.samples.(0) in
         Array.blit fl.samples 0 bigger 0 fl.len;
         fl.samples <- bigger
       end;
       match Typed_id.equal_t id fl.gen_id with
       | Typed_id.Not_Eq -> assert false
       | Typed_id.Eq ->
          fl.samples.(fl.len) <- s;
         fl.len <- fl.len + 1

  let sample tbl (type a) (g : a gen) : a sample =
    let Fraglist fl = H.find tbl (Typed_id.to_int g.id) in (* may raise Not_found *)
    match Typed_id.equal_t g.id fl.gen_id with
    | Typed_id.Not_Eq -> assert false
    | Typed_id.Eq ->
       fl.samples.(Random.int fl.len)
end


let rec split_into :
  type a . Fragment_Pool.t -> a sample -> unit =
  fun tbl s ->
  Fragment_Pool.add tbl s;
  match s.components with
  | SChoose (ch, t) -> split_into tbl t
  | SMap (scases, f) -> split_into_gens tbl scases
  | SPrim _ -> ()

and split_into_gens :
  type k res . Fragment_Pool.t -> (k, res) sample_tuple -> unit =
  fun tbl s -> match s with
  | TNil _ -> ()
  | TCons (s, ss) -> split_into tbl s; split_into_gens tbl ss



(*
let rec recombine :
  type a . Fragment_Pool.t -> a sample -> a sample =
  fun tbl s ->
  if Random.int 100 < 5 then s
  else if Random.int 100 < 10 then Fragment_Pool.sample tbl s.generator
  else match s.components with
  | SChoose (ch, t) -> mk_sample 
*)