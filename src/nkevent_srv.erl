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
-module(nkevent_srv).
-behaviour(gen_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([find_server/1, find_all_servers/1, start_server/1]).
-export([do_call/2]).
-export([start_link/3, get_all/0, dump/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).


-include("nkevent.hrl").


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkEVENT '~s/~s/~s' "++Txt,
        [State#state.class, State#state.sub, State#state.type|Args])).

-define(MOVE_WAIT_TIME, 30000).

%%-define(NO_NKDIST, 1).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec find_server(#nkevent{}) ->
    {ok, pid()} | not_found.

find_server(#nkevent{class=Class, subclass=Sub, type=Type}) ->
    do_find_server(Class, Sub, Type).


%% @private
do_find_server(Class, Sub, Type) ->
    case has_nkdist() of
        false ->
            case nklib_proc:values({?MODULE, Class, Sub, Type}) of
                [{undefined, Pid}] ->
                    {ok, Pid};
                [] ->
                    not_found
            end;
        true ->
            case nkdist:get(nkevent, {Class, Sub, Type}, #{idx=>Class}) of
                {ok, proc, [{_Meta, Pid}]} ->
                    {ok, Pid};
                {error, _} ->
                    not_found
            end
    end.


%% @doc
-spec find_all_servers(#nkevent{}) ->
    [pid()].

find_all_servers(#nkevent{class=Class, subclass=Sub, type=Type}) ->
    List = case {Sub, Type} of
        {<<>>, <<>>} ->
            [{Class, <<>>, <<>>}];
        {_, <<>>} ->
            [{Class, Sub, <<>>}, {Class, <<>>, <<>>}];
        _ ->
            [{Class, Sub, Type}, {Class, Sub, <<>>}, {Class, <<>>, Type}, {Class, <<>>, <<>>}]
    end,
    find_add_servers(List, []).


%% @private
find_add_servers([], Acc) ->
    Acc;

find_add_servers([{Class, Sub, Type}|Rest], Acc) ->
    Acc2 = case do_find_server(Class, Sub, Type) of
        {ok, Pid} -> [Pid|Acc];
        not_found -> Acc
    end,
    find_add_servers(Rest, Acc2).


%% @doc
-spec start_server(#nkevent{}) ->
    {ok, pid()} | {error, term()}.

start_server(#nkevent{class=Class, subclass=Sub, type=Type}) ->
    case has_nkdist() of
        false ->
            Spec = {
                {Class, Sub, Type},
                {?MODULE, start_link, [Class, Sub, Type]},
                temporary,
                5000,
                worker,
                [?MODULE]
            },
            case supervisor:start_child(nkservice_events_sup, Spec) of
                {ok, Pid}  -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, Error} -> {error, Error}
            end;
        true ->
            Args = {dist, Class, Sub, Type},
            case nkdist:gen_server_start(nkevent, {Class, Sub, Type}, #{idx=>Class}, ?MODULE, Args, []) of
                {ok, Pid} -> {ok, Pid};
                {error, {already_registered, Pid}} -> {ok, Pid};
                {error, Error} -> {error, Error}
            end
    end.

%% @private
get_all() ->
    nklib_proc:values(?MODULE).


%% ===================================================================
%% gen_server
%% ===================================================================

-type key() :: {nkevent:srv_id(), nkevent:obj_id()}.

-record(state, {
    class :: nkevent:class(),
    sub :: nkevent:subclass(),
    type :: nkevent:type(),
    regs = #{} :: #{key() => [{pid(), nkevent:domain(), nkevent:body()}]},
    pids = #{} :: #{pid() => {Mon::reference(), [key()]}},
    moved_to = undefined :: pid(),
    stop_after_last = false :: boolean()
}).


%% @private
start_link(Class, Sub, Type) ->
    gen_server:start_link(?MODULE, {Class, Sub, Type}, []).


%% @private
-spec init(term()) ->
    {ok, #state{}}.

init({Class, Sub, Type}) ->
    true = nklib_proc:reg({?MODULE, Class, Sub, Type}),
    nklib_proc:put(?MODULE, {Class, Sub, Type}),
    State = #state{class=Class, sub=Sub, type=Type},
    ?LLOG(debug, "starting server (~p)", [self()], State),
    {ok, State};

init({dist, Class, Sub, Type}) ->
    case nkdist:register(proc, nkevent, {Class, Sub, Type}, #{idx=>Class}) of
        ok ->
            nklib_proc:put(?MODULE, {Class, Sub, Type}),
            State = #state{class=Class, sub=Sub, type=Type},
            ?LLOG(debug, "starting dist server (~p)", [self()], State),
            {ok, State};
        {error, {pid_conflict, Pid}} ->
            {stop, {already_registered, Pid}};
        {error, Error} ->
            {stop, Error}
    end;

init({moved, Class, Sub, Type, Regs, Pid}) ->
    ok = nkdist_reg:register(proc, nkevents, {Class, Sub, Type}, #{sync=>true, replace_pid=>Pid}),
    nklib_proc:put(?MODULE, {Class, Sub, Type}),
    State1 = #state{class=Class, sub=Sub, type=Type},
    State2 = reg_all(maps:to_list(Regs), State1),
    ?LLOG(debug, "starting moved server (~p)", [self()], State2),
    {ok, State2}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} | {stop, normal, ok, #state{}}.

handle_call({call, Event}, _From, State) ->
    #nkevent{class=Class, srv_id=SrvId, obj_id=ObjId, debug=Debug} = Event,
    #state{class=Class, regs=Regs} = State,
    PidTerms = case maps:get({SrvId, ObjId}, Regs, []) of
        [] ->
            case maps:get({SrvId, <<>>}, Regs, []) of
                [] ->
                    case maps:get({any, ObjId}, Regs, []) of
                        [] ->
                            maps:get({any, <<>>}, Regs, []);
                        List ->
                            List
                    end;
                List ->
                    List
            end;
        List ->
            List
    end,
    case Debug of
        true ->
            ?LLOG(debug, "call ~s:~s: ~p", [SrvId, ObjId, PidTerms], State);
        _ ->
            ok
    end,
    case PidTerms of
        [] ->
            {reply, not_found, State};
        _ ->
            Pos = nklib_util:l_timestamp() rem length(PidTerms) + 1,
            {Pid, Dom, RegBody} = lists:nth(Pos, PidTerms),
            send_events([{Pid, Dom, RegBody}], Event#nkevent{pid=undefined}, [], State),
            {reply, ok, State}
    end;

handle_call(dump, _From, #state{regs=Regs, pids=Pids}=State) ->
    {reply, {Regs, map_size(Regs), Pids, map_size(Pids)}, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({send, Event}, #state{moved_to=Pid}) when is_pid(Pid) ->
    gen_server:cast(Pid, {send, Event});

handle_cast({send, Event}, State) ->
    #state{class=Class, regs=Regs} = State,
    #nkevent{class=Class, srv_id=SrvId, obj_id=ObjId, debug=Debug} = Event,
    PidTerms1 = maps:get({SrvId, ObjId}, Regs, []),
    PidTerms2 = maps:get({SrvId, <<>>}, Regs, []),
    PidTerms3 = maps:get({any, ObjId}, Regs, []),
    PidTerms4 = maps:get({any, <<>>}, Regs, []),
    case Debug of
        true ->
            ?LLOG(info, "send ~s:~s ~p,~p,~p,~p",
                [SrvId, ObjId, PidTerms1, PidTerms2, PidTerms3, PidTerms4], State);
        _ ->
            ok
    end,
    Acc1 = send_events(PidTerms1, Event, [], State),
    Acc2 = send_events(PidTerms2, Event, Acc1, State),
    Acc3 = send_events(PidTerms3, Event, Acc2, State),
    _Acc4 = send_events(PidTerms4, Event, Acc3, State),
    {noreply, State};

handle_cast({reg, Event}, State) ->
    #nkevent{srv_id=SrvId, obj_id=ObjId, domain=Domain, body=Body, pid=Pid, debug=Debug} = Event,
    % set_log(SrvId),
    case Debug of
        true ->
            ?LLOG(debug, "registered ~s:~s (~p)", [SrvId, ObjId, Pid], State);
        _ ->
            ok
    end,
    State2 = do_reg(SrvId, ObjId, Domain, Body, Pid, State),
    {noreply, State2};

handle_cast({unreg, Event}, State) ->
    #nkevent{srv_id=SrvId, obj_id=ObjId, pid=Pid, debug=Debug} = Event,
    case Debug of
        true ->
            ?LLOG(debug, "unregistered ~s:~s (~p)", [SrvId, ObjId, Pid], State);
        _ ->
            ok
    end,
    State2 = do_unreg([{SrvId, ObjId}], Pid, State),
    check_stop(State2);

%%handle_cast(remove_all, #state{pids=Pids}=State) ->
%%    ?LLOG(info, "remove all", [], State),
%%    lists:foreach(fun({_Pid, {Mon, _}}) -> demonitor(Mon) end, maps:to_list(Pids)),
%%    {noreply, State#state{regs=#{}, pids=#{}}};

handle_cast({stop_after_last, Bool}, State) ->
    State2 = State#state{stop_after_last = Bool},
    check_stop(State2);

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({'DOWN', Mon, process, Pid, _Reason}, #state{pids=Pids}=State) ->
    case maps:find(Pid, Pids) of
        {ok, {Mon, Keys}} ->
            %% lists:foreach(
            %%    fun({SrvId, ObjId}) ->
            %%        ?LLOG(info, "unregistered ~s:~s (down)", [SrvId, ObjId], State)
            %%    end,
            %%    Keys),
            State2 = do_unreg(Keys, Pid, State),
            check_stop(State2);
        error ->
            lager:warning("Module ~p received unexpected down: ~p", [?MODULE, Pid]),
            {noreply, State}
    end;

%%handle_info({nkservice_updated, SrvId}, State) ->
%%    force_set_log(SrvId),
%%    {noreply, State};

handle_info({nkdist, {vnode_pid, _Pid}}, State) ->
    {noreply, State};

handle_info({nkdist, {must_move, Node}}, #state{class=Class, sub=Sub, type=Type, regs=Regs}=State) ->
    case rpc:call(Node, gen_server, start, [?MODULE, {moved, Class, Sub, Type, Regs}, []]) of
        {ok, NewPid} ->
            ?LLOG(info, "starting move to ~p (~p -> ~p)", [Node, self(), NewPid], State),
            erlang:send_after(?MOVE_WAIT_TIME, self(), move_completed),
            {noreply, State#state{moved_to=NewPid}};
        {error, Error} ->
            ?LLOG(warning, "could not move process to ~p: ~p", [Node, Error], State),
            {noreply, State}
    end;

handle_info({vnode_pid, _Pid}, State) ->
    {noreply, State};

handle_info(move_completed, State) ->
    ?LLOG(info, "move completed", [], State),
    {stop, normal, State};

handle_info(Info, State) ->
    lager:warning("Module ~p received unexpected info ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, State) ->
    ?LLOG(info, "stopping server (~p)", [self()], State),
    ok.



%% ===================================================================
%% Private
%% ===================================================================


%% @private
do_reg(SrvId, ObjId, Domain, Body, Pid, #state{regs=Regs, pids=Pids}=State) ->
    Key = {SrvId, ObjId},
    PidBodyList2 = case maps:find(Key, Regs) of
        {ok, PidBodyList} ->   % [{pid(), domain(), body)}]
            lists:keystore(Pid, 1, PidBodyList, {Pid, Domain, Body});
        error ->
            [{Pid, Domain, Body}]
    end,
    Regs2 = maps:put(Key, PidBodyList2, Regs),
    {Mon2, Keys2} = case maps:find(Pid, Pids) of
        {ok, {Mon, Keys}} ->    % [reference(), [key()]]
            {Mon, nklib_util:store_value(Key, Keys)};
        error ->
            Mon = monitor(process, Pid),
            {Mon, [Key]}
    end,
    Pids2 = maps:put(Pid, {Mon2, Keys2}, Pids),
    State#state{regs=Regs2, pids=Pids2}.


%% @private
do_unreg([], _Pid, State) ->
    State;

do_unreg([Key|Rest], Pid, #state{regs=Regs, pids=Pids}=State) ->
    Regs2 = case maps:find(Key, Regs) of
        {ok, PidBodyList} ->
            case lists:keydelete(Pid, 1, PidBodyList) of
                [] ->
                    maps:remove(Key, Regs);
                PidBodyList2 ->
                    maps:put(Key, PidBodyList2, Regs)
            end;
        error ->
            Regs
    end,
    Pids2 = case maps:find(Pid, Pids) of
        {ok, {Mon, Keys}} ->
            case Keys -- [Key] of
                [] ->
                    demonitor(Mon),
                    maps:remove(Pid, Pids);
                Keys2 ->
                    maps:put(Pid, {Mon, Keys2}, Pids)
            end;
        error ->
            Pids
    end,
    do_unreg(Rest, Pid, State#state{regs=Regs2, pids=Pids2}).


%% @private
send_events([], _Event, Acc, _State) ->
    Acc;

send_events([{Pid, _Domain, _}|Rest], #nkevent{pid=PidE}=Event, Acc, State) when is_pid(PidE), Pid/=PidE ->
    send_events(Rest, Event, Acc, State);

send_events([{Pid, RegDomain, RegBody}|Rest], Event, Acc, State) ->
    case lists:member(Pid, Acc) of
        false ->
            #nkevent{domain=Domain, body=Body, debug=Debug}=Event,
            %% We are subscribed to any domain or the domain of the event
            %% is longer than the registered domain
            case check_domain(RegDomain, Domain) of
                true ->
                    Event2 = Event#nkevent{body=maps:merge(RegBody, Body)},
                    case Debug of
                        true  ->
                            ?LLOG(info,
                                "sending event ~p to ~p", [lager:pr(Event2, ?MODULE), Pid], State);
                        _ ->
                            ok
                    end,
                    Pid ! {nkevent, Event2},
                    send_events(Rest, Event, [Pid|Acc], State);
                false ->
                    send_events(Rest, Event, Acc, State)
            end;
        true ->
            send_events(Rest, Event, Acc, State)
    end.


%% @private
check_domain(<<>>, _) ->
    true;
check_domain(Reg, Domain) ->
    Size = byte_size(Reg),
    case Domain of
        <<Reg:Size/binary, _/binary>> -> true;
        _ -> false
    end.


%% @private
check_stop(#state{pids=Pids, stop_after_last=Stop}=State) ->
    case Stop andalso map_size(Pids)==0 of
        true ->
            {stop, normal, State};
        false ->
            {noreply, State}
    end.


%% @private
reg_all([], State) ->
    State;

reg_all([{{SrvId, ObjId}, PidBodyList}|Rest], State) ->
    State2 = do_reg_all(SrvId, ObjId, PidBodyList, State),
    reg_all(Rest, State2).


%% @private
do_reg_all(_Srv, _ObjId, [], State) ->
    State;

do_reg_all(SrvId, ObjId, [{Pid, Domain, Body}|Rest], State) ->
    State2 = do_reg(SrvId, ObjId, Domain, Body, Pid, State),
    do_reg_all(SrvId, ObjId, Rest, State2).

%%
%%%% @private
%%set_log(SrvId) ->
%%    case get({?MODULE, SrvId}) of
%%        undefined ->
%%            force_set_log(SrvId),
%%            nkservice_util:register_for_changes(SrvId);
%%        _ ->
%%            ok
%%    end.
%%
%%
%%%% @private
%%force_set_log(SrvId) ->
%%    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
%%        {true, _} -> true;
%%        _ -> false
%%    end,
%%    put({?MODULE, SrvId}, Debug).


-ifdef(NO_NKDIST).
has_nkdist() -> false.
-else.
has_nkdist() -> is_pid(whereis(nkdist_sup)).
-endif.


%% @private
do_call(Event, Msg) ->
    do_call(Event, Msg, 5).


%% @private
do_call(_Event, _Msg, 0) ->
    {error, no_process};

do_call(Event, Msg, Tries) ->
    case find_server(Event) of
        {ok, Pid} ->
            case nklib_util:call(Pid, Msg, 5000) of
                ok ->
                    ok;
                {error, _} ->
                    timer:sleep(1000),
                    do_call(Event, Msg, Tries-1)
            end;
        not_found ->
            case start_server(Event) of
                {ok, _} ->
                    do_call(Event, Msg, Tries-1);
                {error, Error} ->
                    {error, Error}
            end
    end.



%%%% @private
%%remove_all(Class, Sub, Type) ->
%%    Class2 = to_bin(Class),
%%    Sub2 = to_bin(Sub),
%%    Type2 = to_bin(Type),
%%    case do_find_server(Class2, Sub2, Type2) of
%%        {ok, Pid} -> gen_server:cast(Pid, remove_all);
%%        not_found -> not_found
%%    end.


%% @private
dump(Class, Sub, Type) ->
    Class2 = to_bin(Class),
    Sub2 = to_bin(Sub),
    Type2 = to_bin(Type),
    {ok, Pid} = do_find_server(Class2, Sub2, Type2),
    gen_server:call(Pid, dump).


%% @private
to_bin(Term) -> nklib_util:to_binary(Term).



%% ===================================================================
%% Tests
%% ===================================================================


-define(TEST, 1).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all]).

basic_test_() ->
    {setup,
        fun() ->
            ?debugFmt("Starting ~p", [?MODULE]),
            test_reset()
        end,
        fun(_Stop) ->
            test_reset()
        end,
        [
            fun test1/0,
            fun test2/0,
            fun test3/0
        ]
    }.


test_reset() ->
    Ev = #nkevent{class = <<"c">>, subclass = <<"s">>, type = <<"t">>},
    case find_server(Ev) of
        {ok, Pid} ->
            gen_server:cast(Pid, stop),
            timer:sleep(50);
        not_found ->
            ok
    end.



test1() ->
    Reg = #nkevent{class=c, subclass=s, type=t, srv_id=srv},
    Self = self(),
    nkevent:reg(Reg#nkevent{obj_id=id1, body=#{b1=>1}}),
    nkevent:reg(Reg#nkevent{obj_id=id2, body=#{b2=>2}}),
    {
        #{
            {srv, <<"id1">>} := [{Self, <<>>, #{b1:=1}}],
            {srv, <<"id2">>} := [{Self, <<>>, #{b2:=2}}]
        },
        2,
        #{
            Self := {_, [{srv, <<"id2">>}, {srv, <<"id1">>}]}
        },
        1
    } =
        dump(c, s, t),

    nkevent:unreg(Reg#nkevent{obj_id=id1}),
    {
        #{{srv, <<"id2">>} := [{Self, <<>>, #{b2:=2}}]},
        1,
        #{Self := {_, [{srv, <<"id2">>}]}},
        1
    } =
        dump(c, s, t),

    nkevent:unreg(Reg#nkevent{obj_id=id3}),
    nkevent:unreg(Reg#nkevent{obj_id=id2}),
    {_, 0, _, 0} = dump(c, s, t),
    ok.


test2() ->
    P1 = test_reg(1, b1),
    P2 = test_reg(1, b1),
    P3 = test_reg(1, b1b),
    P4 = test_reg(2, b2),
    P5 = test_reg(3, b3),
    P6 = test_reg(3, b3b),
    P7 = test_reg(<<>>, b7),
    timer:sleep(50),

    Reg = #nkevent{class=c, subclass=s, type=t, srv_id=srv},
    lists:foreach(
        fun(_) ->
            nkevent:call(Reg#nkevent{obj_id=0}),
            receive
                {c, _RP1, <<"0">>, RB1} ->
                    true = lists:member(RB1, [b1, b1b, b2, b3, b3b, b7]);
                O ->
                    error(O)
            after 100 ->
                error(?LINE)

            end
        end,
        lists:seq(1, 100)),

    lists:foreach(
        fun(_) ->
            nkevent:call(Reg#nkevent{obj_id=1}),
            receive
                {c, _RP2, <<"1">>, RB2} -> true = lists:member(RB2, [b1, b1b, b7])
            after 100 -> error(?LINE)
            end
        end,
        lists:seq(1, 100)),

    lists:foreach(
        fun(_) ->
            nkevent:call(Reg#nkevent{obj_id=2}),
            receive
                {c, RP3, <<"2">>, RB2} ->
                    true = lists:member(RB2, [b2, b7]),
                    true = lists:member(RP3, [P4, P7])
            after 100 ->
                error(?LINE)
            end
        end,
        lists:seq(1, 100)),

    lists:foreach(
        fun(_) ->
            nkevent:call(Reg#nkevent{obj_id=3}),
            receive
                {c, _RP3, <<"3">>, RB2} -> true = lists:member(RB2, [b3, b3b, b7])
            after 100 -> error(?LINE)
            end
        end,
        lists:seq(1, 100)),

    lists:foreach(
        fun(_) ->
            nkevent:call(Reg#nkevent{obj_id=25}),
            receive
                {c, P7, <<"25">>, b7} -> ok
            after 100 -> error(?LINE)
            end
        end,
        lists:seq(1, 100)),

    nkevent:send(Reg#nkevent{obj_id=0}),
    receive {c, P1, <<"0">>, b1} -> ok after 100 -> error(?LINE) end,
    receive {c, P2, <<"0">>, b1} -> ok after 100 -> error(?LINE) end,
    receive {c, P3, <<"0">>, b1b} -> ok after 100 -> error(?LINE) end,
    receive {c, P4, <<"0">>, b2} -> ok after 100 -> error(?LINE) end,
    receive {c, P5, <<"0">>, b3} -> ok after 100 -> error(?LINE) end,
    receive {c, P6, <<"0">>, b3b} -> ok after 100 -> error(?LINE) end,
    receive {c, P7, <<"0">>, b7} -> ok after 100 -> error(?LINE) end,

    nkevent:send(Reg#nkevent{obj_id=1}),
    receive {c, P1, <<"1">>, b1} -> ok after 100 -> error(?LINE) end,
    receive {c, P2, <<"1">>, b1} -> ok after 100 -> error(?LINE) end,
    receive {c, P3, <<"1">>, b1b} -> ok after 100 -> error(?LINE) end,
    receive {c, P7, <<"1">>, b7} -> ok after 100 -> error(?LINE) end,

    nkevent:send(Reg#nkevent{obj_id=2}),
    receive {c, P4, <<"2">>, b2} -> ok after 100 -> error(?LINE) end,
    receive {c, P7, <<"2">>, b7} -> ok after 100 -> error(?LINE) end,

    nkevent:send(Reg#nkevent{obj_id=3}),
    receive {c, P5, <<"3">>, b3} -> ok after 100 -> error(?LINE) end,
    receive {c, P6, <<"3">>, b3b} -> ok after 100 -> error(?LINE) end,
    receive {c, P7, <<"3">>, b7} -> ok after 100 -> error(?LINE) end,

    nkevent:send(Reg#nkevent{obj_id=33}),
    receive {c, P7, <<"33">>, b7} -> ok after 100 -> error(?LINE) end,

    receive _ -> error(?LINE) after 100 -> ok end,

    [P ! stop || P <- [P1, P2, P3, P4, P5, P6, P7]],
    timer:sleep(50),
    {_, 0, _, 0} = dump(c, s, t),
    ok.


test3() ->
    P1 = test_reg(1, b1),
    P2 = test_reg(1, b1),
    P3 = test_reg(1, b1b),
    P4 = test_reg(2, b2),
    P5 = test_reg(3, b3),
    P6 = test_reg(3, b3b),
    P7 = test_reg(<<>>, b7),
    timer:sleep(100),

    {
        #{
            {srv, <<>>} := [{P7, <<>>, #{b7:=1}}],
            {srv, <<"0">>} := L1,
            {srv, <<"1">>} := L2,
            {srv, <<"2">>} := [{P4, <<>>, #{b2:=1}}],
            {srv, <<"3">>} := L3
        },
        5,
        #{
            P1 := {_, [{srv, <<"0">>}, {srv, <<"1">>}]},
            P2 := {_, [{srv, <<"0">>}, {srv, <<"1">>}]},
            P3 := {_, [{srv, <<"0">>}, {srv, <<"1">>}]},
            P4 := {_, [{srv, <<"0">>}, {srv, <<"2">>}]},
            P5 := {_, [{srv, <<"0">>}, {srv, <<"3">>}]},
            P6 := {_, [{srv, <<"0">>}, {srv, <<"3">>}]},
            P7 := {_, [{srv, <<"0">>}, {srv, <<>>}]}
        },
        7
    }
        = dump(c, s, t),

    true = lists:sort(L1) == lists:sort(
        [{P1, <<>>, #{b1=>1}}, {P2, <<>>, #{b1=>1}}, {P3, <<>>, #{b1b=>1}}, {P4, <<>>, #{b2=>1}},
        {P5, <<>>, #{b3=>1}}, {P6, <<>>, #{b3b=>1}}, {P7, <<>>, #{b7=>1}}]),

    true = lists:sort(L2) == lists:sort(
        [{P1, <<>>, #{b1=>1}}, {P2, <<>>, #{b1=>1}}, {P3, <<>>, #{b1b=>1}}]),

    true = lists:sort(L3) == lists:sort([{P5, <<>>, #{b3=>1}}, {P6, <<>>   , #{b3b=>1}}]),

    P1 ! stop,
    P4 ! unreg,
    timer:sleep(100),
    {
        #{
            {srv, <<>>} := [{P7, <<>>, #{b7:=1}}],
            {srv, <<"0">>} := L4,
            {srv, <<"1">>} := L5,
            {srv, <<"3">>} := L6
        },
        4,
        #{
            P2 := {_, [{srv, <<"0">>}, {srv, <<"1">>}]},
            P3 := {_, [{srv, <<"0">>}, {srv, <<"1">>}]},
            P4 := {_, [{srv, <<"0">>}]},
            P5 := {_, [{srv, <<"0">>}, {srv, <<"3">>}]},
            P6 := {_, [{srv, <<"0">>}, {srv, <<"3">>}]},
            P7 := {_, [{srv, <<"0">>}, {srv, <<>>}]}
        },
        6
    } =
        dump(c, s, t),

    true = lists:sort(L4) == lists:sort([
            {P2, <<>>, #{b1=>1}},
            {P3, <<>>, #{b1b=>1}},
            {P4, <<>>, #{b2=>1}},
            {P5, <<>>, #{b3=>1}},
            {P6, <<>>, #{b3b=>1}},
            {P7, <<>>, #{b7=>1}}
    ]),

    true = lists:sort(L5) == lists:sort([{P2, <<>>, #{b1=>1}}, {P3, <<>>, #{b1b=>1}}]),

    true = lists:sort(L6) == lists:sort([{P5, <<>>, #{b3=>1}}, {P6, <<>>, #{b3b=>1}}]),

    [P ! stop || P <- [P1, P2, P3, P4, P5, P6, P7]],
    ok.


test4() ->
    P1 = test_reg(4, <<"/a/b">>, b5),
    timer:sleep(50),
    Reg = #nkevent{class=c, subclass=s, type=t, srv_id=srv},
    nkevent:send(Reg#nkevent{obj_id=4, domain= <<"/a/b">>}),
    nkevent:send(Reg#nkevent{obj_id=4, domain= <<"/a/b/c">>}),
    nkevent:send(Reg#nkevent{obj_id=4, domain= <<"/a/">>}),
    receive {c, P1, <<"4">>, b5} -> ok after 100 -> error(?LINE) end,
    receive {c, P1, <<"4">>, b5} -> ok after 100 -> error(?LINE) end,
    receive {c, P1, <<"4">>, b5} -> ok after 100 -> ok end,
    P1 ! stop,
    ok.



test_reg(I, B) ->
    test_reg(I, <<>>, B).


test_reg(I, Domain, B) ->
    Reg = #nkevent{class=c, subclass=s, type=t, domain=Domain, srv_id=srv},
    Self = self(),
    spawn(
        fun() ->
            nkevent:reg(Reg#nkevent{obj_id=I, body=#{B=>1}}),
            nkevent:reg(Reg#nkevent{obj_id=0, body=#{B=>1}}),
            test_reg_loop(Self, I)
        end).


test_reg_loop(Pid, I) ->
    receive
        {nkevent, Event} ->
            #nkevent{class= <<"c">>, subclass= <<"s">>, type= <<"t">>,
                srv_id=srv, obj_id=Id, body=B} = Event,
            [{B1, 1}] = maps:to_list(B),
            Pid ! {c, self(), Id, B1},
            test_reg_loop(Pid, I);
        stop ->
            ok;
        unreg ->
            nkevent:unreg(#nkevent{class=c, subclass=s, type=t, srv_id=srv, obj_id=I}),
            test_reg_loop(Pid, I);
        _ ->
            error(?LINE)
    after 10000 ->
        ok
    end.


-endif.
