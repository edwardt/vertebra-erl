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

-module(advertiser).

-include("typespecs.hrl").

-define(DEFAULT_TTL, 3600).

-export([advertise/2, advertise/3, unadvertise/2, unadvertise/3]).

%% Advertise resources with the default TTL of 1 hour
-spec(advertise/2 :: (Config :: proplist(), Resources :: [resource()] | []) -> ok | {error, any()}).
advertise(Config, Resources) ->
  advertise(Config, Resources, ?DEFAULT_TTL).

%% Advertise resources with a custom TTTL
-spec(advertise/3 :: (Config :: proplist(), Resources :: [resource()] | [], TTL :: integer()) -> ok | {error, any()}).
advertise(Config, Resources, TTL) ->
  execute_command("/security/advertise", Config, Resources, TTL).

%% Unadvertise a set of resources
-spec(unadvertise/2 :: (Config :: proplist(), Resources :: [resource()] | []) -> ok | {error, any()}).
unadvertise(Config, Resources) ->
  unadvertise(Config, Resources, ?DEFAULT_TTL).

%% Unadvertises a set of resources with a custom TTL
-spec(unadvertise/3 :: (Config :: proplist(), Resources :: [resource] | [], TTL :: integer) -> ok | {error, any()}).
unadvertise(Config, Resources, TTL) ->
  execute_command("/security/unadvertise", Config, Resources, TTL).

%% Internal functions

convert_login(Config) ->
  Token = uuid_server:generate_uuid(),
  [{resource, Token} | lists:filter(fun({Name, _Value}) ->
                                        if
                                          Name =:= resource ->
                                            false;
                                          true ->
                                            true
                                        end end, Config)].

execute_command(Op, Config, Resources, TTL) ->
  Login = convert_login(Config),
  Token = proplists:get_value(resource, Login),
  Res = vertebra_xmpp:build_resources(Resources),
  HeraultJid = proplists:get_value(herault, Login),
  AdvertiserJid = lists:flatten([proplists:get_value(username, Login), "@",
                                 proplists:get_value(host, Login), "/",
                                 proplists:get_value(username, Login)]),
  Inputs = [{string, [{"name", "advertiser"}], list_to_binary(AdvertiserJid)},
            {list, [{"name", "resources"}], Res},
            {integer, [{"name", "ttl"}], TTL}],
  case vertebra_command:run(Login, Op, Inputs, Token, HeraultJid) of
    {ok, _, _} ->
      ok;
    Error ->
      Error
  end.
