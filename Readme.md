
## ppx_jsobject_conv

Ppx plugins for Typeconv to derive conversion from ocaml types to js objects to use with js_of_ocaml.

# Example

```ocaml

type stuff = int * string * float [@@deriving jsobject]

type status = Created | Registered of int | Deleted of stuff [@@deriving jsobject]

type user = {
    name: string;
    age: int;
    status: status
} [@@deriving jsobject]

```
