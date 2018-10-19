%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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
-module(nkevent).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([send/1, reg/1, unreg/1]).
-export([call/1]).
-export([set_stop_after_last/2]).

-include("nkevent.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type event() :: #nkevent{} | event_data().

-type event_data() ::
    #{
        srv_id => srv_id(),
        class => class(),
        subclass => subclass(),
        type => type() | [type()],
        obj_id => obj_id(),
        domain => domain(),
        body => body()
    }.

% Native formats are binary. Atoms will be converted to binaries.
-type srv_id() :: atom() | any.
-type class() :: atom() | binary().
-type subclass() :: atom() | binary().
-type type() :: atom() | binary().
-type obj_id() :: atom() | binary().
-type domain() :: atom() | binary().
-type body() :: map().



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an event
%% It will be sent to processes that registered Class, SubClass, Type and ObjId, and also
%% to processes that registered any ObjId, any Type and any SubClass
%% It is sent to processes that registered the included srv_id and also the ones that
%% registered 'any'
%% If domain is included, is used as a prefix
%% If a pid is included in the event, it is sent only to that pid
%% If a body is included, it will be merged with any registered process one
%% Processed will receive and event {nkevent, Event}
-spec send(event()) ->
    ok.

send(Event) ->
    Event2 = nkevent_util:normalize(Event),
    %lager:warning("EVENT ~p", [Event2]),
    lists:foreach(
        fun(Server) ->
            %lager:warning("SEND ~p", [Server]),
            gen_server:cast(Server, {send, Event2})
        end,
        nkevent_srv:find_all_servers(Event2)).


%% @doc
-spec call(event()) ->
    ok | not_found.

call(Event) ->
    Event2 = nkevent_util:normalize(Event),
    Pids = nkevent_srv:find_all_servers(Event2),
    do_call(Pids, Event2).


%% @private
do_call([], _Event) ->
    not_found;

do_call([Pid|Rest], Event) ->
    case gen_server:call(Pid, {call, Event}) of
        ok ->
            ok;
        _ ->
            do_call(Rest, Event)
    end.


%% @doc Register to receive events
%% missing or <<>> fields mean 'any'
%% you should monitor the pid() and re-register if it fails
-spec reg(event()) ->
    {ok, [pid()]} | {error, term()}.

reg(Event) ->
    case nkevent_util:parse_reg(Event) of
        {ok, Events} ->
            do_reg(Events, []);
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_reg([], Acc) ->
    {ok, Acc};

do_reg([Event|Rest], Acc) ->
    Event2 = nkevent_util:normalize_self(Event),
    case do_reg_find(Event2, 50) of
        {ok, Pid} ->
            gen_server:cast(Pid, {reg, Event2}),
            do_reg(Rest, nklib_util:store_value(Pid, Acc));
        error ->
            {error, could_not_start_server}
    end.


%% @private
do_reg_find(Event, Count) when Count > 0 ->
    case nkevent_srv:find_server(Event) of
        {ok, Pid} ->
            {ok, Pid};
        not_found ->
            case nkevent_srv:start_server(Event) of
                {ok, Pid} ->
                    {ok, Pid};
                {error, Error} ->
                    lager:notice("NkEVENT retrying registration: ~p", [Error]),
                    timer:sleep(100),
                    do_reg_find(Event, Count-1)
            end
    end;

do_reg_find(Event, _Count) ->
    lager:warning("NkEVENT could not register ~p", [lager:pr(Event, ?MODULE)]),
    error.




%% @doc
-spec unreg(event()) ->
    ok.

unreg(Event) ->
    case nkevent_util:parse_reg(Event) of
        {ok, Events} ->
            do_unreg(Events);
        {error, Error} ->
            {error, Error}
    end.

%% @private
do_unreg([]) ->
    ok;

do_unreg([Event|Rest]) ->
    Event2 = nkevent_util:normalize_self(Event),
    case nkevent_srv:find_server(Event2) of
        {ok, Pid} ->
            gen_server:cast(Pid, {unreg, Event2});
        not_found ->
            ok
    end,
    do_unreg(Rest).


%% @private
set_stop_after_last(Event, Bool) when is_boolean(Bool) ->
    Event2 = nkevent_util:normalize_self(Event),
    case nkevent_srv:find_server(Event2) of
        {ok, Pid} ->
            gen_server:cast(Pid, {stop_after_last, Bool});
        not_found ->
            ok
    end.




