%%%----------------------------------------------------------------------
%%% File    : mod_websocket.erl
%%% Author  : Nathan Zorn <nathan.zorn@gmail.com>
%%% Purpose : XMPP over websockets
%%%----------------------------------------------------------------------

-module(mod_websocket).
-author('nathan.zorn@gmail.com').

-define(MOD_WEBSOCKET_VERSION, "0.1").
-define(TEST, ok).
-define(PROCNAME_MHB, ejabberd_mod_websocket).

-behaviour(gen_mod).

-export([
	start/2,
	stop/1,
	process/2
]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("websocket_session.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
process(_Path, Req) ->
	%% Validate Origin
	case validate_origin(Req#wsrequest.headers) of
		true ->
			?DEBUG("Origin is valid.", []),

			case Req#wsrequest.data of
				Data when is_binary(Data) ->
					?DEBUG("Binary data.", []),
 %         case process_data(WSDataState) of
						%{<<>>, Part} when is_binary(Part) ->
							%?DEBUG("Processed partial: ~p", [Part]),
							%{<<>>, Part};

						%{Out, <<>>} when is_binary(Out) ->
							%?DEBUG("Processed packet: ~p", [Out]),
							%IP = Req#wsrequest.ip,
							%%% websocket frame is finished process request
							%ejabberd_xmpp_websocket:process_request(
								%Req#wsrequest.wsockmod,
								%Req#wsrequest.wsocket,
								%Req#wsrequest.fsmref,
								%Out,
								%IP);

						%Error ->
							%?DEBUG("Error: ~p", [{error, invalid_websocket_data, Error}]),
							%{error, invalid_websocket_data, Error}
					%end;
					ok;

				socket_closed ->
					IP = Req#wsrequest.ip,
					ejabberd_xmpp_websocket:process_request(
						Req#wsrequest.wsockmod,
						Req#wsrequest.wsocket,
						Req#wsrequest.fsmref,
						<<"</stream:stream>">>,
						IP);

				Error -> {error, invalid_websocket_data, Error}
			end;
		_ ->
			?DEBUG("Invalid Origin in Request: ~p~n",[Req]),
			false
	end.

%%%----------------------------------------------------------------------
%%% BEHAVIOUR CALLBACKS
%%%----------------------------------------------------------------------
start(Host, _Opts) ->
		?WARNING_MSG("~p loaded on ~s", [?MODULE, Host]),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME_MHB),
    ChildSpec =
        {Proc,
         {ejabberd_tmp_sup, start_link,
          [Proc, websocket_xmpp]},
         permanent,
         infinity,
         supervisor,
         [ejabberd_tmp_sup]},
		?DEBUG("WEBSOCKETS SUPERVISOR SPEC: ~p", [ChildSpec]),
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME_MHB),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

%% Origin validator - Ejabberd configuration should contain a fun
%% validating the origin for this request handler? Default is to
%% always validate.
validate_origin([]) ->
	true;
validate_origin(Headers) ->
	is_tuple(lists:keyfind("Origin", 1, Headers)).


%%
%% Tests
%%
-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

%websocket_process_data_test() ->
    %%% Test frame arrival.
    %Packets = [<<0,"<tagname>",255>>,
               %<<0,"<startag> ">>,
               %<<"cdata in startag ">>,
               %<<"more cdata </startag>",255>>,
               %<<0,"something about tests",255>>,
               %<<0,"fragment">>],
    %FakeState = #wsdatastate{ legacy=true,
                              %ft=undefined,
                              %buffer= <<>>,
                              %partial= <<>> },

    %Buffer = <<>>,
    %Packet = lists:nth(1,Packets),
    %FinalState = process_data(FakeState#wsdatastate{buffer= <<Buffer/binary,Packet/binary>>}),
    %{<<"<tagname>">>,<<>>} = FinalState,
    %Packet0 = lists:nth(2,Packets),
    %{_,Buffer0} = FinalState,
    %FinalState0 = process_data(FakeState#wsdatastate{buffer= <<Buffer0/binary,Packet0/binary>>}),
    %{<<>>,<<"<startag> ">>} = FinalState0,
    %Packet1 = lists:nth(3,Packets),
    %{_,Buffer1} = FinalState0,
    %FinalState1 = process_data(FakeState#wsdatastate{buffer= <<Buffer1/binary,Packet1/binary>>}),
    %{<<>>,<<"<startag> cdata in startag ">>} = FinalState1,
    %Packet2 = lists:nth(4,Packets),
    %{_, Buffer2} = FinalState1,
    %FinalState2 = process_data(FakeState#wsdatastate{buffer= <<Buffer2/binary,Packet2/binary>>}),
    %{<<"<startag> cdata in startag more cdata </startag>">>,<<>>} = FinalState2,
    %Packet3 = lists:nth(5,Packets),
    %{_,Buffer3} = FinalState2,
    %FinalState3 = process_data(FakeState#wsdatastate{buffer= <<Buffer3/binary,Packet3/binary>>}),
    %{<<"something about tests">>,<<>>} = FinalState3,
    %ok.

-endif.
