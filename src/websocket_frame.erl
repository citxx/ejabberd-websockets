-module(websocket_frame).

-export([
	get_payload/1,
	make/1,
	make/2,
	make_binary/1,
	make_binary/2,
	make_close/0,
	make_close/2,
	make_close/3,
	make_ping/0,
	make_ping/1,
	make_ping/2,
	make_pong/1,
	make_pong/2,
	new_parsing_state/0,
	parse_stream/1,
	parse_stream/2,
	to_binary/1
]).

-export_types([
		ws_parsing_state/0,
		frame/0
	]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("websocket_frame.hrl").

-record(ws_parsing_state, {
		step = read_header ::
			read_header | read_length | read_l_length | read_xl_length |
			read_masking_key | read_payload_data,
		current_frame = #ws_frame{} :: frame(),
		data = <<>> :: binary(),
		frames = [] :: [frame()]
	}).

-type parsing_state() :: #ws_parsing_state{}.
-type frame() :: #ws_frame{}.

%-------------------------------------------------------------------------------
% API
%-------------------------------------------------------------------------------

-spec new_parsing_state() -> parsing_state().
new_parsing_state() -> #ws_parsing_state{}.

-spec make(iodata()) -> frame().
make(Data) ->
	make(Data, []).

-spec make(iodata(), [term()]) -> frame().
make(Data, Options) ->
	Fin = boolean_to_integer(proplists:get_value(fin, Options, true)),
	Rsv1 = boolean_to_integer(proplists:get_value(rsv1, Options, false)),
	Rsv2 = boolean_to_integer(proplists:get_value(rsv2, Options, false)),
	Rsv3 = boolean_to_integer(proplists:get_value(rsv3, Options, false)),
	Opcode = proplists:get_value(opcode, Options, 1),
	{Mask, MaskingKey} = case proplists:get_value(masking_key, Options) of
		undefined -> {0, <<>>};
		Key -> {1, Key}
	end,
	DataBin = iolist_to_binary(Data),
	#ws_frame{
		fin = Fin,
		rsv1 = Rsv1,
		rsv2 = Rsv2,
		rsv3 = Rsv3,
		opcode = Opcode,
		mask = Mask,
		masking_key = MaskingKey,
		payload_length = byte_size(DataBin),
		payload_data = DataBin
	}.

-spec make_binary(iodata()) -> frame().
make_binary(Data) ->
	make_binary(Data, []).

-spec make_binary(iodata(), [term()]) -> frame().
make_binary(Data, Options) ->
	make(Data, [{opcode, ?WS_OPCODE_BINARY} | Options]).

-spec make_ping() -> frame().
make_ping() ->
	make_ping(<<>>).

-spec make_ping(iodata()) -> frame().
make_ping(Data) ->
	make_ping(Data, []).

-spec make_ping(iodata(), [term()]) -> frame().
make_ping(Data, Options) ->
	make(Data, [{opcode, ?WS_OPCODE_PING} | Options]).

-spec make_pong(iodata()) -> frame().
make_pong(Data) ->
	make_pong(Data, []).

-spec make_pong(iodata(), [term()]) -> frame().
make_pong(Data, Options) ->
	make(Data, [{opcode, ?WS_OPCODE_PONG} | Options]).

-spec make_close() -> frame().
make_close() ->
	make(<<>>, [{opcode, ?WS_OPCODE_CLOSE}]).

-spec make_close(integer(), iodata()) -> frame().
make_close(Code, Data) ->
	make_close(Code, Data, []).

-spec make_close(integer(), iodata(), [term()]) -> frame().
make_close(Code, Data, Options) ->
	make([<<Code:16>>, Data], [{?WS_OPCODE_CLOSE, 16#8} | Options]).

-spec to_binary(frame()) -> binary().
to_binary(#ws_frame{
		fin = Fin,
		rsv1 = Rsv1,
		rsv2 = Rsv2,
		rsv3 = Rsv3,
		opcode = Opcode,
		mask = Mask,
		masking_key = MaskingKey,
		payload_length = PayloadLength,
		payload_data = PayloadData
	}) ->
	Header = <<Fin:1, Rsv1:1, Rsv2:1, Rsv3:1, Opcode:4>>,
	WithLength = if
		PayloadLength < 126 ->
			<<Header/binary, Mask:1, PayloadLength:7>>;
		PayloadLength < 65536 ->
			<<Header/binary, Mask:1, 126:7, PayloadLength:16>>;
		true ->
			<<Header/binary, Mask:1, 127:7, PayloadLength:64>>
	end,
	WithMaskingKey = case Mask of
		0 -> WithLength;
		1 -> <<WithLength/binary, MaskingKey:32>>
	end,
	FrameData = case Mask of
		0 -> PayloadData;
		1 -> mask(PayloadData, MaskingKey)
	end,
	Frame = <<WithMaskingKey/binary, FrameData/binary>>,
	Frame.

-spec get_payload(frame()) -> binary().
get_payload(#ws_frame{payload_data = Data}) ->
	Data.


%-------------------------------------------------------------------------------
% Frames parsing fsm
%-------------------------------------------------------------------------------

-spec parse_stream(parsing_state(), binary()) -> {[frame()], parsing_state()}.
parse_stream(#ws_parsing_state{data = Data} = State, NewData) ->
	parse_stream(State#ws_parsing_state{
			data = <<Data/binary, NewData/binary>>
		}).

-spec parse_stream(binary() | parsing_state()) -> {[frame()], parsing_state()}.
parse_stream(Data) when is_binary(Data) ->
	parse_stream(new_parsing_state(), Data);

parse_stream(#ws_parsing_state{
		step = read_header,
		current_frame = Frame,
		data = <<Fin:1, Rsv1:1, Rsv2:1, Rsv3:1, Opcode:4, Rest/binary>>
	} = State) ->
	parse_stream(State#ws_parsing_state{
			step = read_length,
			current_frame = Frame#ws_frame{
				fin = Fin,
				rsv1 = Rsv1,
				rsv2 = Rsv2,
				rsv3 = Rsv3,
				opcode = Opcode},
			data = Rest
		});

parse_stream(#ws_parsing_state{
		step = read_length,
		current_frame = Frame,
		data = <<Mask:1, Length:7, Rest/binary>>
	} = State) ->
	case Length of
		126 ->
			parse_stream(State#ws_parsing_state{
					step = read_l_length,
					current_frame = Frame#ws_frame{mask = Mask},
					data = Rest
				});

		127 ->
			parse_stream(State#ws_parsing_state{
					step = read_xl_length,
					current_frame = Frame#ws_frame{mask = Mask},
					data = Rest
				});

		L ->
			parse_stream(State#ws_parsing_state{
					step = read_masking_key,
					current_frame = Frame#ws_frame{
						mask = Mask,
						payload_length = L},
					data = Rest
				})
	end;

parse_stream(#ws_parsing_state{
		step = read_l_length,
		current_frame = Frame,
		data = <<Length:16, Rest/binary>>
	} = State) ->
	parse_stream(State#ws_parsing_state{
			step = read_masking_key,
			current_frame = Frame#ws_frame{payload_length = Length},
			data = Rest
		});

parse_stream(#ws_parsing_state{
		step = read_xl_length,
		current_frame = Frame,
		data = <<Length:64, Rest/binary>>
	} = State) ->
	parse_stream(State#ws_parsing_state{
			step = read_masking_key,
			current_frame = Frame#ws_frame{payload_length = Length},
			data = Rest
		});

parse_stream(#ws_parsing_state{
		step = read_masking_key,
		current_frame = #ws_frame{mask = 0} = Frame
	} = State) ->
	parse_stream(State#ws_parsing_state{
			step = read_payload_data,
			current_frame = Frame#ws_frame{masking_key = <<0>>}
		});

parse_stream(#ws_parsing_state{
		step = read_masking_key,
		current_frame = #ws_frame{mask = 1} = Frame,
		data = <<MaskingKey:4/binary, Rest/binary>>
	} = State) ->
	parse_stream(State#ws_parsing_state{
			step = read_payload_data,
			current_frame = Frame#ws_frame{masking_key = MaskingKey},
			data = Rest
		});

parse_stream(#ws_parsing_state{
		step = read_payload_data,
		current_frame = #ws_frame{
			fin = Fin,
			rsv1 = Rsv1,
			rsv2 = Rsv2,
			rsv3 = Rsv3,
			opcode = Opcode,
			mask = Mask,
			masking_key = MaskingKey,
			payload_length = Length} = Frame,
		data = Data,
		frames = OldFrames
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

	NewFrame = Frame#ws_frame{payload_data = PayloadData},

	parse_stream(#ws_parsing_state{
			step = read_header,
			current_frame = #ws_frame{},
			data = Rest,
			frames = OldFrames ++ [NewFrame]
		});

parse_stream(#ws_parsing_state{
		frames = Frames
	} = State) ->
	{Frames, State#ws_parsing_state{frames = []}}.


%-------------------------------------------------------------------------------
% Internal functions
%-------------------------------------------------------------------------------

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

-spec boolean_to_integer(boolean() | 0 | 1) -> 0 | 1.
boolean_to_integer(true) -> 1;
boolean_to_integer(false) -> 0;
boolean_to_integer(1) -> 1;
boolean_to_integer(0) -> 0.
