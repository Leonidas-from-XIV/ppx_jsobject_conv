
open Result

let map f e = match e with
  | Ok x -> Ok (f x)
  | Error s -> Error s

let flat_map f e = match e with
  | Ok x -> f x
  | Error s -> Error s

let (>|=) e f = map f e

let (>>=) e f = flat_map f e

let result_of_bool v er = if v then Ok(v) else Error(er)

(* of_jsobject *)
(* heplers *)

let is_array obj  =
  result_of_bool (Js.instanceof obj Js.array_empty)
                 ("Expected array, got: " ^
                    (Js.to_bytestring @@ Js.typeof obj))
  >|= (fun _ ->
    let arr:'a Js.t #Js.js_array Js.t = Js.Unsafe.coerce obj
    in arr)

let array_length (arr : 'a Js.t #Js.js_array Js.t) : int =
  (Js.Unsafe.meth_call arr "length" [||])

let is_array_of_size_n obj expected =
  is_array obj >>=
    (fun arr ->
      let got = array_length arr in
      result_of_bool (expected = got)
                     (Printf.sprintf
                        "Expected array of length %d, got: %d"
                        expected got)
      >|= (fun _ -> arr))

let array_get_or_error arr ind =
  match Js.Optdef.to_option @@ Js.array_get arr ind with
  | Some v -> Ok(v)
  | None -> Error("Expceted value at index" ^ (string_of_int ind))

(* conversion *)
let int_of_jsobject_res num =
  if Js.typeof num = (Js.string "number")
  then Ok(int_of_float @@
            Js.float_of_number @@
              Js.Unsafe.coerce num)
  else Error("not a number")

let float_of_jsobject_res num =
  if Js.typeof num = (Js.string "number")
  then Ok(Js.float_of_number @@
            Js.Unsafe.coerce num)
  else Error("not a number")

let string_of_jsobject_res st =
  if Js.typeof st = (Js.string "string")
  then Ok(Js.to_string (Js.Unsafe.coerce st))
  else Error("not a string")

(* jsobject_of *)
(* helpers *)
let inject o = Js.Unsafe.inject o

let new_array l =
  Js.Unsafe.new_obj Js.array_length [| inject l |]

let to_js_array l =
  let arr = new_array @@ List.length l in
  let set = Js.array_set arr in
  let () = List.iteri set l in
  arr

let make_jsobject pairs =
  inject @@ Js.Unsafe.obj @@ pairs

let number_of_int i = Js.number_of_float @@ float_of_int i

(* conversions *)

let jsobject_of_int v = inject @@ number_of_int v
let jsobject_of_string v = inject @@ Js.string v
let jsobject_of_float v = inject @@ Js.number_of_float v

let jsobject_of_option jsobject_of__a = function
  | Some(x) -> jsobject_of__a x
  | None -> inject @@ Js.null

let jsobject_of_list jsobject_of__a lst =
  to_js_array @@ List.rev  @@ List.rev_map jsobject_of__a lst
let jsobject_of_array jsobject_of__a arr =
  to_js_array @@ Array.to_list @@ Array.map jsobject_of__a arr

module Js = Js
module Result = Result
