port module Main exposing (..)

import Browser
import Browser.Navigation as Nav
import Url
import Html exposing (table, tr, td, text)
import Html.Events exposing (onClick)
import Json.Decode as D
import Piroxy

port toPiroxy : String -> Cmd msg
port fromPiroxy : (String -> msg) -> Sub msg

main =
    Browser.application {
        init=init,
        onUrlChange=UrlChanged,
        onUrlRequest=LinkClicked,
        update=update,
        view=view,
        subscriptions=subscriptions
    }

type alias Model = {log: List Piroxy.Msg}

init : () -> Url.Url -> Nav.Key -> (Model, Cmd Msg)
init flags url key =
    ({log=[]}, Cmd.none)

{-
type alias VagueEntry = {
    id: Integer, spawnid: Integer, secs: Float,
    method: String, arg: String, host: String
}
-}

type Msg = Received String | LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url | Send String

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
    case msg of
        Received json ->
            case D.decodeString Piroxy.decoder json of
                Ok pimsg ->
                    let log = model.log in
                    (Model (pimsg::log), Cmd.none)
                Err err ->
                    let
                        _ = D.errorToString err |> Debug.log "Json.Decode"
                    in
                        (model, Cmd.none)
        LinkClicked _ ->
            (model, Cmd.none)
        UrlChanged _ ->
            (model, Cmd.none)
        Send str ->
            (model, toPiroxy str)


subscriptions : Model -> Sub Msg
subscriptions model =
    fromPiroxy Received

view : Model -> Browser.Document Msg
view model =
    let
        ents = model.log
    in
    {title="Messages", body=[table [] (List.reverse (List.map termRow ents))]}

termRow : Piroxy.Msg -> Html.Html idk
termRow msg =
    case msg of
        Piroxy.New entry ->
            let
                cols =
                    [String.fromInt entry.id, String.fromInt entry.metaid,
                    String.fromFloat entry.time, stringFromAct entry.act,
                    entry.arg]
            in
            tr [] <| List.map tdwrap cols

tdwrap str =
    td [] [text str]

stringFromAct : Piroxy.Act -> String
stringFromAct act1 =
    case act1 of
        Piroxy.Get -> "get"
        Piroxy.Post -> "post"
        Piroxy.Put -> "put"
        Piroxy.Options -> "options"
        Piroxy.Delete -> "delete"
        Piroxy.Patch -> "patch"
        Piroxy.Head -> "head"
        Piroxy.Send -> "send"
        Piroxy.Recv -> "recv"

