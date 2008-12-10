-module(vertebra_xmpp_new).

-export([confirm_op/7, get_named_arg/2, get_token/1]).
-export([send_set/4, send_wait_set/4, send_result/5]).
-export([build_resources/1]).

send_set(XMPP, TrackInfo, To, Body) when is_tuple(TrackInfo), is_tuple(Body) ->
  send_set(XMPP, TrackInfo, To, natter_parser:element_to_string(Body));

send_set(XMPP, TrackInfo, To, Body) when is_tuple(TrackInfo), is_list(Body) ->
  natter_connection:send_iq(XMPP, "set", new_packet_id(), To, Body).

send_wait_set(XMPP, TrackInfo, To, Body) when is_tuple(TrackInfo), is_tuple(Body) ->
  send_wait_set(XMPP, TrackInfo, To, natter_parser:element_to_string(Body));

send_wait_set(XMPP, TrackInfo, To, Body) when is_tuple(TrackInfo), is_list(Body) ->
  io:format("Sending (~s): ~s~n", [To, lists:flatten(Body)]),
  Response = natter_connection:send_wait_iq(XMPP, "set", new_packet_id(), To, Body),
  io:format("Sent (~s): ~p~nReceived: ~p~n", [To, lists:flatten(Body), Response]),
  Response.

send_result(XMPP, TrackInfo, To, PacketId, Body) when is_tuple(TrackInfo), is_tuple(Body) ->
  send_result(XMPP, TrackInfo, To, PacketId, natter_parser:element_to_string(Body));

send_result(XMPP, TrackInfo, PacketId, To, Body) when is_tuple(TrackInfo), is_list(Body) ->
  natter_connection:send_iq(XMPP, "result", PacketId, To, Body).

confirm_op(XMPP, TrackInfo, From, Op, Token, PacketId, IsAck) ->
  {xmlelement, Name, OpAttrs, SubEls} = Op,
  case Name =:= "ack" of
    true ->
      ok;
    false ->
      FinalOpAttrs = dict:store("token", Token, dict:from_list(OpAttrs)),
      send_result(XMPP, TrackInfo, PacketId, From, {xmlelement, Name, dict:to_list(FinalOpAttrs), SubEls}),
      case IsAck of
	true ->
	  send_wait_set(XMPP, TrackInfo, From, ops_builder:ack_op(Token));
	false ->
	  send_wait_set(XMPP, TrackInfo, From, ops_builder:nack_op(Token))
      end
  end.

get_named_arg(Name, Op) ->
  {ok, Args} = xml_util:convert(from, get_args(Op)),
  find_arg(Name, Args).

get_token([{xmlelement, Name, Attrs, _}=H|_T]) when Name =:= "op";
                                                    Name =:= "ack";
                                                    Name =:= "result";
                                                    Name =:= "final" ->
  case proplists:get_value("token", Attrs) of
    undefined ->
      undefined;
    Token ->
      {H, Token}
  end;
get_token([_H|T]) ->
  get_token(T);
get_token([]) ->
  undefined.

build_resources(Resources) ->
  build_resources(Resources, []).

%% Internal functions
get_args(Op) ->
  {xmlelement, "op", _Attrs, SubEls} = Op,
  SubEls.

find_arg(Name, [{_Type, Attrs, _Value}=H|T]) ->
  case proplists:get_value("name", Attrs) of
    Name ->
      H;
    _ ->
      find_arg(Name, T)
  end;
find_arg(_Name, []) ->
  not_found.

build_resources([H|T], Accum) when is_list(H) ->
  build_resources(T, [{resource, [{"name", H}], list_to_binary(H)}|Accum]);
build_resources([H|T], Accum) when is_binary(H) ->
  build_resources(T, [{resource, [{"name", binary_to_list(H)}], H}|Accum]);
build_resources([], Accum) ->
  lists:reverse(Accum).

new_packet_id() ->
  {T1, T2, T3} = erlang:now(),
  random:seed(T1, T2, T3),
  integer_to_list(random:uniform(T1) + random:uniform(T2)).
