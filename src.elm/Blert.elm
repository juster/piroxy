module Blert exposing (..) --(encode, decode, toString)

{- Decode blertjs output (that has been encoded in Json) and encode back.
-}

import Json.Decode as D
import Json.Encode as E

type alias Blert2 = (Term, Term)

type alias Blert3 = (Term, Term, Term)

type Term =
    BlertS String | BlertI Int | BlertF Float |
    BlertL (List Term) | Blert2 (Term, Term) | Blert3 (Term, Term, Term) |
    BlertA String
    -- Map Dict Term Term

encode : Term -> E.Value
encode term =
    case term of
        BlertS str -> E.string str
        BlertI i -> E.int i
        BlertF f -> E.float f
        BlertL lst -> E.object [("list", E.list encode lst)]
        Blert2 (a,b) -> E.object [("tuple", E.list encode [a,b])]
        Blert3 (a,b,c) -> E.object [("tuple", E.list encode [a,b,c])]
        BlertA s -> E.object [("atom", E.string s)]

decode : D.Decoder Term
decode =
    D.oneOf [
        decodeString, decodeInt, decodeFloat, decodeList,
        decodeTuple2, decodeAtom
    ]

decodeString = D.map BlertS D.string
decodeInt = D.map BlertI D.int
decodeFloat = D.map BlertF D.float

decodeList : D.Decoder Term
decodeList =
    let lst = D.map BlertL (D.list (D.lazy (\_ -> decode)))
    in D.field "list" lst

decodeTuple2 : D.Decoder Term
decodeTuple2 =
    D.map2 blertPair
        (D.index 0 (D.lazy (\_ -> decode)))
        (D.index 1 (D.lazy (\_ -> decode)))

blertPair a b =
    Blert2 (a,b)

decodeAtom : D.Decoder Term
decodeAtom = D.field "atom" decodeList

toString : Term -> String
toString term =
    case term of
        BlertA s -> s
        BlertS str -> "\"" ++ (String.replace "\"" "\\\"" str) ++ "\""
        BlertF f -> String.fromFloat(f)
        BlertI i -> String.fromInt(i)
        BlertL lst ->
            "[" ++ (lst |> List.map toString |> String.join ", ") ++ "]"
        Blert2 (a,b) ->
            "{" ++ toString(a) ++ "," ++ toString(b) ++ "}"
        Blert3 (a,b,c) ->
            "{" ++ toString(a) ++ "," ++ toString(b) ++ "," ++ toString(c) ++ "}"

