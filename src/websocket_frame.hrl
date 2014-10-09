-record(ws_frame, {
		fin = undefined :: undefined | 0..1,
		rsv1 = undefined :: undefined | 0..1,
		rsv2 = undefined :: undefined | 0..1,
		rsv3 = undefined :: undefined | 0..1,
		opcode = undefined :: undefined | integer(),
		mask = undefined :: undefined | 0..1,
		payload_length = undefined :: undefined | integer(),
		masking_key = <<0>> :: binary(),
		payload_data = <<>> :: binary()
	}).

% Data frames
-define(WS_OPCODE_CONTINUATION, 16#0).
-define(WS_OPCODE_TEXT, 16#1).
-define(WS_OPCODE_BINARY, 16#2).

% Control frames
-define(WS_OPCODE_CLOSE, 16#8).
-define(WS_OPCODE_PING, 16#9).
-define(WS_OPCODE_PONG, 16#a).

% Close reasons defined at http://tools.ietf.org/html/rfc6455#section-7.4
-define(WS_CLOSE_NORMAL, 1000).
-define(WS_CLOSE_GO_AWAY, 1001).
-define(WS_CLOSE_PROTOCOL_ERROR, 1002).
-define(WS_CLOSE_UNSUPPORTED_DATA_TYPE, 1003).
-define(WS_CLOSE_INCONSISTENT_DATA, 1007).
-define(WS_CLOSE_POLICY_VIOLATED, 1008).
-define(WS_CLOSE_TOO_BIG_FRAME, 1009).
-define(WS_CLOSE_NEED_MORE_EXTENSIONS, 1010).
-define(WS_CLOSE_UNEXPECTED_CONDITION, 1011).
