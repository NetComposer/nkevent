%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Main functions
-module(nkevent_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([parse/1, parse_subs/1, unparse/1]).
-export([normalize/1, normalize_self/1]).

-include("nkevent.hrl").


%% ===================================================================
%% Public functions
%% ===================================================================


%% @doc Tries to parse a event-type object
-spec parse(nkevent:event()) ->
    {ok, #nkevent{}} | {error, term()}.

parse(#nkevent{}=Event) ->
    {ok, Event, []};

parse(Data) ->
    do_parse(Data, false).


%% @doc
-spec parse_subs(nkevent:event()) ->
    {ok, [#nkevent{}]} | {error, term()}.

parse_subs(Data) ->
    case do_parse(Data, true) of
        {ok, #nkevent{type=Types}=Event} ->
            Events = [Event#nkevent{type=Type} || Type <- Types],
            {ok, Events};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_parse(Data, Multi) ->
    Syntax = #{
        srv_id => atom,
        class => binary,
        subclass => binary,
        type =>
        case Multi of
            true -> {list, binary};
            false -> binary
        end,
        obj_id => binary,
        body => map,
        '__defaults' => #{
            subclass => <<>>,
            type => <<>>,
            obj_id => <<>>
        },
        '__mandatory' => [class]
    },
    case nklib_syntax:parse(Data, Syntax) of
        {ok, Parsed, _Exp, []} ->
            #{
                class := Class,
                subclass := Sub,
                type := Type,
                obj_id := ObjId
            } = Parsed,
            Event = #nkevent{
                srv_id = maps:get(srv_id, Data, undefined),
                class = Class,
                subclass = Sub,
                type = Type,
                obj_id = ObjId,
                body = maps:get(body, Parsed, #{})
            },
            {ok, Event};
        {ok, _, _, [Field|_]} ->
            {error, {unrecognized_field, Field}};
        {error, {syntax_error, Error}} ->
            {error, {syntax_error, Error}};
        {error, {missing_mandatory_field, Field}} ->
            {error, {missing_field, Field}};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Tries to parse a event-type object
-spec unparse(#nkevent{}) ->
    map().

unparse(Event) ->
    #nkevent{
        srv_id = _SrvId,
        class = Class,
        subclass = Sub,
        type = Type,
        obj_id = ObjId,
        body = Body
    } = Event,
    Base = [
        {class, Class},
        case to_bin(Sub) of
            <<>> -> [];
            Sub2 -> {subclass, Sub2}
        end,
        case to_bin(Type) of
            <<>> -> [];
            Type2 -> {type, Type2}
        end,
        case to_bin(ObjId) of
            <<>> -> [];
            ObjId2 -> {obj_id, ObjId2}
        end,
        case is_map(Body) andalso map_size(Body) > 0 of
            true -> {body, Body};
            _ -> []
        end
    ],
    maps:from_list(lists:flatten(Base)).


%% @private
normalize(Event) ->
    #nkevent{
        srv_id = SrvId,
        class = Class,
        subclass = Sub,
        type = Type,
        obj_id = ObjId,
        body = Body,
        pid = Pid
    } = Event,
    SrvId2 = case SrvId of
        undefined -> any;
        _ -> SrvId
    end,
    Body2 = case is_map(Body) of
        true ->
            Body;
        false ->
            lager:warning("~p is not a map (~s:~s:~s)", [Body, Class, Sub, Type]),
            #{}
    end,
    Pid2 = case is_pid(Pid) orelse Pid==undefined of
        true ->
            Pid;
        false ->
            lager:warning("~p is not a pid (~s:~s:~s)", [Pid, Class, Sub, Type]),
            undefined
    end,
    Event#nkevent{
        srv_id = SrvId2,
        class = to_bin(Class),
        subclass = to_bin(Sub),
        type = to_bin(Type),
        obj_id = to_bin(ObjId),
        body = Body2,
        pid = Pid2
    }.


%% @private
normalize_self(#nkevent{pid=Pid}=Event) ->
    Event2 = normalize(Event),
    case Pid of
        undefined -> Event2#nkevent{pid=self()};
        _ -> Event2
    end.



%% @private
to_bin(Term) -> nklib_util:to_binary(Term).

