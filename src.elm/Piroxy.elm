module Piroxy exposing (Msg(..), Act(..), LogEntry, decoder)

import Json.Decode as D
import Json.Encode as E

type alias LogEntry = {
    id: Int,
    metaid: Int,
    time: Float,
    act: Act
    }

type alias HostInfo = {
    host: String,
    portNo: Int, -- Can't use "port:"
    secure: Bool
    }

type SubProto = Http | Https

type Act = Connect HostInfo | Get | Post | Put | Options |
    Delete | Patch | Head | Send | Recv

type Msg = New LogEntry

decoder : D.Decoder Msg
decoder =
    D.field "tuple" (D.index 0 D.string |> D.andThen dispatchTag)

dispatchTag tag =
    case tag of
        "new" -> decodeNew
        _ -> D.fail <| "unknown tag: "++tag

-- Erlang: {new, {Id, Time, Act, Arg}}
decodeNew : D.Decoder Msg
decodeNew =
    D.index 1 (
        D.field "tuple" (
            D.map5 LogEntry
            (D.index 0 D.int)
            (D.index 1 D.int)
            (D.index 2 D.float)
            (D.index 2 decodeAct)
            |>
            D.map New
        )
    )

decodeAct : D.Decoder Act
decodeAct =
    D.field "atom" D.string |> D.andThen dispatchAct

dispatchAct : String -> D.Decoder Act
dispatchAct act =
    case act of
        "connect" -> decodeConnect
        "get" -> D.succeed Get
        "post" -> D.succeed Post
        "options" -> D.succeed Options
        "delete" -> D.succeed Delete
        "patch" -> D.succeed Patch
        "head" -> D.succeed Head
        "send" -> D.succeed Send
        "recv" -> D.succeed Recv
        _ -> D.fail <| "unknown act: "++act

decodeConnect : D.Decoder Act
decodeConnect =

