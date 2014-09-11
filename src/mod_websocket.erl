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

-record(ws_data_state, {
	step = read_header ::
		read_header | read_length | read_l_length | read_xl_length |
		read_masking_key | read_payload_data,
	fin = undefined :: undefined | boolean(),
	rsv1 = undefined :: undefined | 0..1,
	rsv2 = undefined :: undefined | 0..1,
	rsv3 = undefined :: undefined | 0..1,
	opcode = undefined :: undefined | integer(),
	mask = undefined :: undefined | 0..1,
	payload_length = undefined :: undefined | integer(),
	masking_key = <<0>> :: binary(),
	buffer = <<>> :: binary(),
	data = <<>> :: binary(),
	partial = <<>> :: binary()
}).
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
					WSDataState = #ws_data_state{
						data = Data,
						partial = Data
					},
					case process_data(WSDataState) of
						{<<>>, Part} when is_binary(Part) ->
							?DEBUG("Processed partial: ~p", [Part]),
							{<<>>, Part};

						{Out, <<>>} when is_binary(Out) ->
							?DEBUG("Processed packet: ~p", [Out]),
							IP = Req#wsrequest.ip,
							%% websocket frame is finished process request
							ejabberd_xmpp_websocket:process_request(
								Req#wsrequest.wsockmod,
								Req#wsrequest.wsocket,
								Req#wsrequest.fsmref,
								Out,
								IP);

						Error ->
							?DEBUG("Error: ~p", [{error, invalid_websocket_data, Error}]),
							{error, invalid_websocket_data, Error}
					end;

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
          [Proc, ejabberd_xmpp_websocket]},
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

process_data(#ws_data_state{
		step = read_header,
		data = <<Fin:1, Rsv1:1, Rsv2:1, Rsv3:1, Opcode:4, Rest/binary>>
	} = State) ->
	process_data(State#ws_data_state{
			step = read_length,
			fin = Fin,
			rsv1 = Rsv1,
			rsv2 = Rsv2,
			rsv3 = Rsv3,
			opcode = Opcode,
			data = Rest
		});

process_data(#ws_data_state{
		step = read_length,
		data = <<Mask:1, Length:7, Rest/binary>>
	} = State) ->
	case Length of
		126 ->
			process_data(State#ws_data_state{
					step = read_l_length,
					mask = Mask,
					data = Rest
				});

		127 ->
			process_data(State#ws_data_state{
					step = read_xl_length,
					mask = Mask,
					data = Rest
				});

		L ->
			process_data(State#ws_data_state{
					step = read_masking_key,
					mask = Mask,
					payload_length = L,
					data = Rest
				})
	end;

process_data(#ws_data_state{
		step = read_l_length,
		data = <<Length:16, Rest/binary>>
	} = State) ->
	process_data(State#ws_data_state{
			step = read_masking_key,
			payload_length = Length,
			data = Rest
		});

process_data(#ws_data_state{
		step = read_xl_length,
		data = <<Length:64, Rest/binary>>
	} = State) ->
	process_data(State#ws_data_state{
			step = read_masking_key,
			payload_length = Length,
			data = Rest
		});

process_data(#ws_data_state{
		step = read_masking_key,
		mask = 0
	} = State) ->
	process_data(State#ws_data_state{
			step = read_payload_data,
			masking_key = <<0>>
		});

process_data(#ws_data_state{
		step = read_masking_key,
		mask = 1,
		data = <<MaskingKey:4/binary, Rest/binary>>
	} = State) ->
	process_data(State#ws_data_state{
			step = read_payload_data,
			masking_key = MaskingKey,
			data = Rest
		});

process_data(#ws_data_state{
		step = read_payload_data,
		fin = Fin,
		rsv1 = Rsv1,
		rsv2 = Rsv2,
		rsv3 = Rsv3,
		opcode = Opcode,
		mask = Mask,
		masking_key = MaskingKey,
		payload_length = Length,
		buffer = _Buffer,
		data = Data
	} = _State) when byte_size(Data) >= Length ->
	<<MaskedPayloadData:Length/binary, Rest/binary>> = Data,

	PayloadData = mask(MaskedPayloadData, MaskingKey),

	?DEBUG("Received a WebSocket frame:~n"
		"  FIN = ~p~n"
		"  RSV1 = ~p~n"
		"  RSV2 = ~p~n"
		"  RSV3 = ~p~n"
		"  Opcode = ~p~n"
		"  MASK = ~p~n"
		"  Payload length = ~p~n"
		"  Masking key = ~p~n"
		"  Payload data = ~p~n",
		[Fin, Rsv1, Rsv2, Rsv3, Opcode, Mask, Length, MaskingKey, PayloadData]),

	{PayloadData, Rest};

process_data(#ws_data_state{
		partial = Partial
	} = State) ->
	?DEBUG("Not enough data. State: ~p", [State]),
	{<<>>, Partial}.


-spec mask(binary(), binary()) -> binary().
mask(Data, Key) ->
	mask1(Data, Key, <<>>).

mask1(<<>>, _Key, Result) ->
	Result;
mask1(<<DataByte:8, DataRest/binary>>, <<KeyByte:8, KeyRest/binary>>, Result) ->
	mask1(
		DataRest,
		<<KeyRest/binary, KeyByte>>,
		<<Result/binary, (DataByte bxor KeyByte)>>).

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
