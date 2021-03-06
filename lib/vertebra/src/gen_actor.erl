% Copyright 2008, Engine Yard, Inc.
%
% This file is part of Vertebra.
%
% Vertebra is free software: you can redistribute it and/or modify it under the
% terms of the GNU Lesser General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option) any
% later version.
%
% Vertebra is distributed in the hope that it will be useful, but WITHOUT ANY
% WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
% A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more
% details.
%
% You should have received a copy of the GNU Lesser General Public License
% along with Vertebra.  If not, see <http://www.gnu.org/licenses/>.

% Generic behavior useful for implementing Vertebra actors in Erlang.
% This module wraps all the underlying Vertebra details (IQ set/results,
% acking/nacking, etc) and presents a simple API for writing actors.
-module(gen_actor).

-behaviour(gen_server).

-include("typespecs.hrl").

-define(DEFAULT_TTL, 3600).

-define(BAD_PACKET_ERR, {xmlelement, "error", [{"code", "406"},
                                               {"type", "modify"}], [{xmlelement, "not-acceptable", [{"xmlns", "urn:ietf:params:xml:ns:xmpp-stanzas"}], []}]}).
-define(MISSING_VERT_ELEMENT_ERR, {xmlelement, "error", [{"code", "400"}], [{xmlcdata, <<"Missing required Vertebra element">>}]}).


%% API
-export([start_link/3, get_connection_info/1]).
-export([send_error/4, send_result/4, end_result/3]).
-export([add_resources/2, remove_resources/2, stop/1]).
-export([is_duplicate/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% gen_actor callbacks
-export([behaviour_info/1]).

-record(state,
        {xmpp,
         xmpp_config,
         cb_module,
         tracker_pid,
         advertiser,
         packet_fingerprints=[]}).

%%====================================================================
%% API
%%====================================================================
behaviour_info(callbacks) ->
  [{advertised_resources, 0},
   {handle_op, 5},
   {is_secure, 1}].

start_link(NameScope, Config, CallbackModule) when is_tuple(NameScope),
                                                   is_list(Config),
                                                   is_atom(CallbackModule) ->
  gen_server:start_link(NameScope, ?MODULE, [Config, CallbackModule], []).

% Has the actor seen this stanza before?
% This is typically called from the process dispatching the incoming request
-spec(is_duplicate/2 :: (ServerPid :: pid(), Stanza :: xmlelement()) -> true | false).
is_duplicate(ServerPid, Stanza) ->
  gen_server:call(ServerPid, {is_duplicate, Stanza}).

% Retrieve the XMPP connection for this agent
-spec(get_connection_info/1 :: (ServerPid :: pid()) -> pid()).
get_connection_info(ServerPid) ->
  gen_server:call(ServerPid, get_xmpp_connection_info).

% These functions are used by actors

% Send a Vertebra error to a client
-spec(send_error/4 :: (SeverPid :: pid(), To :: string(), Token :: string(), Error :: string()) -> ok | {error, any()}).
send_error(ServerPid, To, Token, Error) ->
  XMPP = get_connection_info(ServerPid),
  ErrStanza = vertebra_protocol:error(Error, Token),
  RetryFun = fun() -> vertebra_xmpp:send_wait_set(XMPP, {}, To, ErrStanza) end,
  transmit(ServerPid, XMPP, {RetryFun, To}).

% Send a single Vertebra data stanza
-spec(send_result/4 :: (ServerPid :: pid(), To :: string(), Token :: string(), Result :: any()) -> ok | {error, any()}).
send_result(ServerPid, To, Token, Result) ->
  XMPP = get_connection_info(ServerPid),
  ResultStanza = vertebra_protocol:data(Result, Token),
  RetryFun = fun() -> vertebra_xmpp:send_wait_set(XMPP, {}, To, ResultStanza) end,
  transmit(ServerPid, XMPP, {RetryFun, To}).

% Send Vertebra final stanza
-spec(end_result/3 :: (ServerPid :: pid(), To :: string(), Token :: string()) -> ok | {error, any()}).
end_result(ServerPid, To, Token) ->
  XMPP = get_connection_info(ServerPid),
  Final = vertebra_protocol:final(Token),
  RetryFun = fun() -> vertebra_xmpp:send_wait_set(XMPP, {}, To, Final) end,
  transmit(ServerPid, XMPP, {RetryFun, To}).

% Adds a resource advertisement at runtime
% Delegates to the advertiser module
-spec(add_resources/2 :: (ServerPid :: pid(), Resources :: [resource()] | []) -> ok | {error, any()}).
add_resources(ServerPid, Resources) ->
  gen_server:call(ServerPid, {add_resources, Resources}).

% Removes a resource advertisement at runtime
% Delegates to the advertiser module
-spec(remove_resources/2 :: (ServerPid :: pid(), Resources :: [resource()] | []) -> ok | {error, any()}).
remove_resources(ServerPid, Resources) ->
  gen_server:call(ServerPid, {remove_resources, Resources}).

stop(ServerPid) ->
  gen_server:cast(ServerPid, stop).

init([Config, CallbackModule]) ->
  application:start(crypto),
  {ok, Cn} = case proplists:get_value(fuzzer, Config) of
               undefined ->
                 natter_connection:start_link(Config);
               {InspectorMod, ConfigFile} ->
                 {ok, InspectorPid} = InspectorMod:start_link(ConfigFile, vertebra_util:jid_from_config(Config)),
                 natter_connection:start_link(Config, InspectorMod, InspectorPid)
             end,
  natter_connection:register_default_exchange(Cn, self()),
  State = case proplists:get_value(herault, Config) of
            undefined ->
              #state{xmpp=Cn, cb_module=CallbackModule, xmpp_config=Config};
            _ ->
              {ok, P} = start_advertiser(Config, CallbackModule:advertised_resources()),
              #state{xmpp=Cn, cb_module=CallbackModule, xmpp_config=Config, advertiser=P}
          end,
  {ok, State#state{tracker_pid=vertebra_tracker:start_link(Cn)}}.

handle_call(get_xmpp_connection_info, _From, State) ->
  {reply, State#state.xmpp, State};

handle_call({remove_resources, Resources}, _From, State) ->
  gen_actor_advertiser:remove_resources(State#state.advertiser, Resources),
  {reply, ok, State};

handle_call({add_resources, Resources}, _From, State) ->
  gen_actor_advertiser:add_resources(State#state.advertiser, Resources),
  {reply, ok, State};

handle_call({is_duplicate, Stanza}, _From, State) ->
  StanzaFingerprint = build_fingerprint(Stanza),
  {Result, NewState} = find_duplicate(StanzaFingerprint, State#state.packet_fingerprints, State),
  {reply, Result, NewState};

handle_call(_Msg, _From, State) ->
  {reply, ignored, State}.

handle_cast(stop, State) ->
  {stop, shutdown, State};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({packet, {xmlelement, "iq", Attrs, SubEls}=Stanza}, State) ->
  StanzaFingerprint = build_fingerprint(Stanza),
  case find_duplicate(StanzaFingerprint, State#state.packet_fingerprints, State) of
    {true, State} ->
      {noreply, State};
    {false, NewState} ->
      From = proplists:get_value("from", Attrs),
      case proplists:get_value("type", Attrs) of
        "result" ->
          ok;
        Type when Type =:= "get";
                  Type =:= "set" ->
          case find_vertebra_element(SubEls) of
            undefined ->
              natter_connection:send_iq(State#state.xmpp, "error", "", From, natter_parser:element_to_string(?MISSING_VERT_ELEMENT_ERR));
            {xmlelement, _, OpAttrs, _} = Op ->
              From = proplists:get_value("from", Attrs),
              PacketId = proplists:get_value("id", Attrs),
              Token = proplists:get_value("token", OpAttrs),
              Me = self(),
              proc_lib:spawn(fun() -> dispatch(Me, State, From, PacketId, rotate_token(Token), Op) end)
          end;
        _ ->
          From = proplists:get_value("from", Attrs),
          Reply = {xmlelement, "message", [{"to", From}, {"type", "error"}], [?BAD_PACKET_ERR]},
          natter_connection:raw_send(State#state.xmpp, natter_parser:element_to_string(Reply))
      end,
      {noreply, NewState}
  end;

handle_info({packet, {xmlelement, "message", Attrs, _}}, State) ->
  From = proplists:get_value("from", Attrs),
  Reply = {xmlelement, "message", [{"to", From}, {"type", "error"}], [?BAD_PACKET_ERR]},
  natter_connection:raw_send(State#state.xmpp, natter_parser:element_to_string(Reply)),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Internal functions
transmit(ServerPid, XMPP, {XmitFun, To}=Xmitter) ->
  case XmitFun() of
    {ok, Reply} ->
      case handle_reply(ServerPid, Reply) of
        ok ->
          Reply;
        retry ->
          transmit(ServerPid, XMPP, Xmitter);
        duplicate ->
          case clear_duplicate(ServerPid, To, Reply) of
            true ->
              transmit(ServerPid, XMPP, Xmitter);
            false ->
              {error, {abort, duplicate}}
          end;
        cancel ->
          {error, {abort, Reply}}
      end;
    Error ->
      Error
  end.


rotate_token(Token) ->
  Parts = string:tokens(Token, ":"),
  case length(Parts) of
    1 ->
      lists:flatten([Parts, ":", uuid_server:generate_uuid()]);
    2 ->
      lists:flatten([lists:nth(2, Parts), ":", uuid_server:generate_uuid()])
  end.

verify_permissions(Config, Herault, Caller, Resources) ->
  case vertebra_auth:verify(Config, Herault, Caller, Resources) of
    {ok, Result} ->
      Result;
    _ ->
      false
  end.

dispatch(ServerPid, ServerState, From, PacketId, Token, Op) ->
  #state{xmpp=Connection, xmpp_config=Config, cb_module=Mod} = ServerState,
  {xmlelement, OpName, _, Children} = Op,
  CanContinue = case Mod:is_secure(OpName) of
                  true ->
                    verify_permissions(Config,
                                       proplists:get_value(herault, Config),
                                       From,
                                       [OpName|extract_resources(Children, [])]);
                  false ->
                    true
                end,
  if
    CanContinue =:= true ->
      vertebra_xmpp:confirm_op(Connection, {}, From, Op, Token, PacketId, true),
      run_callback(ServerPid, ServerState, From, Token, Op);
    true ->
      vertebra_xmpp:confirm_op(Connection, {}, From, Op, Token, PacketId, false)
  end.

run_callback(ServerPid, ServerState, From, Token, Op) ->
  {xmlelement, "op", Attrs, _} = Op,
  OpName = proplists:get_value("type", Attrs),
  Args = [OpName, ServerPid, From, Token, Op],
  try
    apply(ServerState#state.cb_module, handle_op, Args)
  catch
    error:undef ->
      Error = lists:flatten(["No handler for op: ", OpName]),
      vertebra_xmpp:send_wait_set(ServerState#state.xmpp, {}, From, vertebra_protocol:error("fatal", Error, Token)),
      vertebra_xmpp:send_wait_set(ServerState#state.xmpp, {}, From, vertebra_protocol:final(Token))
  end.

find_vertebra_element([{xmlelement, Name, _, _}=H|_T]) when Name =:= "op";
                                                            Name =:= "ack";
                                                            Name =:= "data";
                                                            Name =:= "final" ->
  H;
find_vertebra_element([_H|T]) ->
  find_vertebra_element(T);
find_vertebra_element([]) ->
  undefined.

start_advertiser(Config, {}) ->
  gen_actor_advertiser:start_link(Config, [], ?DEFAULT_TTL);
start_advertiser(Config, {Resources}) ->
  gen_actor_advertiser:start_link(Config, Resources, ?DEFAULT_TTL);
start_advertiser(Config, {TTL, Resources}) ->
  gen_actor_advertiser:start_link(Config, Resources, TTL).

extract_resources([{xmlelement, "resource", _, [{xmlcdata, Resource}]}|T], Accum) ->
  extract_resources(T, [binary_to_list(Resource)|Accum]);
extract_resources([{xmlelement, "list", _, SubEls}|T], Accum) ->
  extract_resources(T, extract_resources(SubEls, Accum));
extract_resources([_|T], Accum) ->
  extract_resources(T, Accum);
extract_resources([], Accum) ->
  lists:reverse(Accum).

handle_reply(ServerPid, Reply) ->
  case gen_actor:is_duplicate(ServerPid, Reply) of
    true ->
      duplicate;
    false ->
      case vertebra_error_policy:analyze(Reply) of
        wait ->
          timer:sleep(500),
          retry;
        Result ->
          Result
      end
  end.

build_fingerprint({xmlelement, _, Attrs, _}) ->
  From = proplists:get_value("from", Attrs),
  Id = proplists:get_value("id", Attrs),
  {From, Id}.

find_duplicate(Fingerprint, [Fingerprint|_T], State) ->
  {true, State};
find_duplicate(Fingerprint, [_|T], State) ->
  find_duplicate(Fingerprint, T, State);
find_duplicate(Fingerprint, [], #state{packet_fingerprints=Fingerprints}=State) ->
  UpdatedFingerprints = case length(Fingerprints) of
                          5 ->
                            lists:reverse(lists:nthtail(1, lists:reverse(Fingerprints)));
                          _ ->
                            Fingerprints
                        end,
  {false, State#state{packet_fingerprints=[Fingerprint|UpdatedFingerprints]}}.

%% TODO: Implement actions necessary to "clear" the duplicate
%% stanza sent by the caller. For more details, see Jay and/or
%% Sam.
clear_duplicate(ServerPid, To, {xmlelement, "iq", _Attrs, _SubEls}) ->
  false.
