%%%-----------------------------------------------------------------------------
%%% File    : websocket_session.erl
%%% Author  : Artem Tabolin <artemtab@yandex.ru>
%%%           Based on Nathan Zorn's ejabberd_websocket module
%%% Purpose : Implementation of WebSockets protocol
%%%           Listener for XMPP over websockets protocol
%%%-----------------------------------------------------------------------------

-module(websocket_session).
-author('artemtab@yandex.ru').

-behaviour(gen_fsm).

%% API
-export([
		start_link/2,
		send/2,
		close/1,
		close/3
	]).

%% Listener callbacks
-export([
		become_controller/1,
		socket_type/0,
		start/2,
		transform_listen_option/2
	]).

%% gen_fsm callbacks
-export([
		handle_info/3,
		init/1,
		terminate/3
	]).

-export([
		ws_closing/2,
		ws_handshake_request/2,
		ws_handshake_header/2,
		ws_session/2,
		ws_setup/2
	]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("websocket_frame.hrl").


-type process_reference() :: atom() | {atom(), atom()} | {global, term()} | pid().
-type request_handler() :: {list(binary()), atom()}.

%% record used to keep WebSocket session state
-record(ws_state, {
		sockmod :: atom(),
		socket :: inet:socket(),
		request_handlers = [] :: list(request_handler()),
		request_method = undefined :: undefined | atom() | binary(),
		request_version = undefined :: undefined | {integer(), integer()},
		request_path = undefined :: undefined | [binary()],
		request_headers = orddict:from_list([]) :: orddict:orddict(),
		parsing_state = websocket_frame:new_parsing_state() ::
			websocket_frame:parsing_state(),
		xmpp_ref = undefined,
		receiving_frames = false
	}).

%-------------------------------------------------------------------------------
% API
%-------------------------------------------------------------------------------

start_link(SockData, Opts) ->
	gen_fsm:start_link(?MODULE, [SockData, Opts], []).


-spec send(process_reference(), iodata()) -> ok.
send(WsSessionRef, Message) ->
	gen_fsm:send_event(WsSessionRef, {send, Message}),
	ok.

-spec close(process_reference(), integer(), term()) -> ok.
close(WsSessionRef, Code, Reason) ->
	gen_fsm:send_event(WsSessionRef, {close, Code, Reason}),
	ok.

-spec close(process_reference()) -> ok.
close(WsSessionRef) ->
	gen_fsm:send_event(WsSessionRef, close),
	ok.


%-------------------------------------------------------------------------------
% Listener callbacks
%-------------------------------------------------------------------------------

-spec start({atom(), inet:socket()}, [term()]) -> any(). 
start(SockData, Opts) ->
	supervisor:start_child(websocket_session_sup, [SockData, Opts]).

become_controller(_Pid) ->
	ok.

socket_type() ->
	raw.

transform_listen_option({request_handlers, Hs}, Opts) ->
	Hs1 = lists:map(
		fun({Path, Mod}) ->
				{to_normalized_path(Path), Mod}
		end, Hs),
	[{request_handlers, Hs1} | Opts];
transform_listen_option(Opt, Opts) ->
	[Opt|Opts].


%-------------------------------------------------------------------------------
% gen_fsm callbacks
%-------------------------------------------------------------------------------

init([{SockMod, Socket}, Opts]) ->
	?DEBUG("Start WebSocket connection ~p via ~p with options: ~p", [self(), SockMod, Opts]),
	SslEnabled = proplists:get_bool(tls, Opts),
	SslOpts1 = [Opt || {certfile, _} = Opt <- Opts],
	SslOpts = [{verify, verify_none} | SslOpts1],

	setopts(SockMod, Socket, [{recbuf, 8192}]),
	case SslEnabled of
		true -> gen_fsm:send_event(self(), {setup, {ssl, SslOpts}});
		false -> gen_fsm:send_event(self(), {setup, tcp})
	end,

	RequestHandlers = case lists:keysearch(request_handlers, 1, Opts) of
		{value, {request_handlers, H}} -> H;
		false -> []
	end,

	State = #ws_state{sockmod = SockMod,
		socket = Socket,
		request_handlers = RequestHandlers},
	{ok, ws_setup, State}.

terminate(Reason, StateName, _State) ->
	?DEBUG("Stop WebSocket connection ~p in state ~p because of ~p", [self(), StateName, Reason]),
	ok.

handle_info({_Type, _Sock, Data}, StateName, #ws_state{
		sockmod = SockMod,
		socket = Socket,
		parsing_state = ParsingState,
		receiving_frames = ReceivingFrames
	} = State) ->
	?DEBUG("Recieved raw data from WebSocket: ~p", [Data]),
	SwitchToRaw = case Data of
		http_eoh -> [{packet, raw}];
		_ -> []
	end,
	StateRF = case Data of
		http_eoh -> State#ws_state{receiving_frames = true};
		_ -> State
	end,

	% TODO: add request handlers support
	% TODO: validate origin
	NewState = case ReceivingFrames of
		false ->
			gen_fsm:send_event(self(), {recv, Data}),
			StateRF;
		true ->
			{Frames, NewParsingState} = websocket_frame:parse_stream(ParsingState, Data),
			lists:foreach(fun(Frame) ->
						gen_fsm:send_event(self(), {recv, Frame})
				end, Frames),
			State#ws_state{parsing_state = NewParsingState}
	end,

	setopts(SockMod, Socket, [{active, once} | SwitchToRaw]),
	{next_state, StateName, NewState};

% TODO: proper tcp_closed handling
handle_info({tcp_closed, _Socket}, _StateName, State) ->
	{stop, {error, "Client closed tcp connection unexpectedly"}, State};

handle_info({ssl_closed, _Socket}, _StateName, State) ->
	{stop, {error, "Client closed ssl connection unexpectedly"}, State};

handle_info(Message, StateName, State) ->
	?WARNING_MSG("~p:handle_info: unexpected message recieved in state ~p: ~p", [?MODULE, StateName, Message]),
	{stop, {error, {unexpected_message, Message, StateName}}, State}.


ws_setup({setup, tcp}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	setopts(SockMod, Socket, [{packet, http}, {active, once}]),
	{next_state, ws_handshake_request, State};

ws_setup({setup, {ssl, Opts}}, #ws_state{
		sockmod = gen_tcp,
		socket = Socket
	} = State) ->
	case ssl:ssl_accept(Socket, Opts) of
		{ok, SSLSocket} ->
			?DEBUG("Upgrade WebSocket connection ~p to ssl", [self()]),
			setopts(ssl, SSLSocket, [{packet, http}, {active, once}]),
			{next_state, ws_handshake_request, State#ws_state{
					sockmod = ssl,
					socket = SSLSocket
				}};
		{error, closed} ->
			{stop, normal, State};
		{error, not_owner} ->
			{stop, normal, State};
		Error ->
			?ERROR_MSG("Error while upgrading WebSocket connection ~p to ssl: ~p", [{self(), inet:peername(Socket)}, Error]),
			gen_tcp:close(Socket),
			{stop, {error, Error}, State}
	end.


% TODO: add tcp_error handling
ws_handshake_request(
		{recv, {http_request, Method, Uri, Version}},
		#ws_state{} = State) ->
	% TODO: error handling
	RawPath = case Uri of
		{absoluteURI, _Scheme, _Host, _Port, P} -> P;
		{scheme, _Scheme, P} -> P;
		{abs_path, P} -> P;
		P -> P
	end,
	Path = case (catch url_decode_q_split(RawPath)) of 
		{'EXIT', _} -> undefined;
		{NPath, _Query} -> 
			LPath = [path_decode(NPE) || NPE <- string:tokens(NPath, "/")],
			to_normalized_path(LPath)
	end,
	{next_state, ws_handshake_header, State#ws_state{
			request_version = Version,
			request_method = Method,
			request_path = Path
		}};

ws_handshake_request(Event, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	?WARNING_MSG(
		"Unexpected event received in state ws_handshake_request:~n"
		"  Event = ~p~n"
		"  State = ~p~n",
		[Event, State]),
	Response = build_http_response({1, 1}, 400, "Bad request", []),
	SockMod:send(Socket, Response),
	SockMod:close(Socket),
	{stop, {error, "Got invalid http request"}, State}.
	
ws_handshake_header({recv, {http_header, _, Name, _, Value}}, #ws_state{
		request_headers = Headers
	} = State) ->
	{next_state, ws_handshake_header, State#ws_state{
			request_headers = add_header(Name, Value, Headers)
		}};

ws_handshake_header({recv, http_eoh}, #ws_state{
		sockmod = SockMod,
		socket = Socket,
		request_handlers = RequestHandlers,
		request_method = Method,
		request_version = {VMaj, VMin} = Version,
		request_path = Path,
		request_headers = Headers
	} = State) ->
	Host = orddict_get("host", Headers, []),
	Upgrade = [jlib:tolower(X) || X <- orddict_get("upgrade", Headers, [])],
	Connection = [jlib:tolower(X) || X <- orddict_get("connection", Headers, [])],
	SecWebSocketKey = orddict_get("sec-websocket-key", Headers, []),
	SecWebSocketVersion = orddict_get("sec-websocket-version", Headers, []),
	SecWebSocketProtocol = orddict_get("sec-websocket-protocol", Headers, []),
	
	UpgradeContainsWebsocket = lists:member("websocket", Upgrade),
	ConnectionContainsUpgrade = lists:member("upgrade", Connection),
	ProtocolContainsXmpp = lists:member("xmpp", SecWebSocketProtocol),
	?DEBUG("Search for ~p in ~p", [Path, RequestHandlers]),
	MatchedRequestHandler = case Path of 
		undefined -> undefined;
		P -> find_request_handler(RequestHandlers, P)
	end,

	{Status, Response} = if
		Method =/= 'GET' ->
			{failure, build_http_response(
					Version, 400, "Bad request: invalid method", [])};
		(VMaj < 1) or (VMaj =:= 1) and (VMin < 1) ->
			{failure, build_http_response(
					Version, 400, "Bad request: need HTTP/1.1 or higher", [])};
		length(Host) =/= 1 ->
			{failure, build_http_response(
					Version, 400, "Bad request: need exactly one 'Host' header", [])};
		not UpgradeContainsWebsocket ->
			{failure, build_http_response(
						Version, 400, "Bad request: 'Upgrade' header doesn't include 'websocket'", [])};
		not ConnectionContainsUpgrade ->
			{failure, build_http_response(
					Version, 400, "Bad request: 'Connection' header doesn't include 'upgrade'", [])};
		not ProtocolContainsXmpp ->
			{failure, build_http_response(
					Version, 400, "Bad request: 'Sec-WebSocket-Protocol' doesn't include 'xmpp'", [])};
		length(SecWebSocketKey) =/= 1 ->
			{failure, build_http_response(
					Version, 400, "Bad request: need exactly one 'Sec-WebSocket-Key' header", [])};
		length(SecWebSocketVersion) =/= 1 ->
			{failure, build_http_response(
					Version, 400, "Bad request: need exactly one 'Sec-WebSocket-Version' header", [])};
		SecWebSocketVersion =/= ["13"] -> 
			{failure, build_http_response(
					Version, 400, "Bad request: unsupported version of WebSocket protocol", [])};
		MatchedRequestHandler =:= undefined ->
			{failure, build_http_response(
					Version, 404, "Not found", [])};

		true ->
			?DEBUG("Switching to WebSocket protocol", []),
			[Key] = SecWebSocketKey,
			ResponseKey = websocket_transform_key(Key),
			{success, build_http_response(
					Version, 101, "Switching protocol to XMPP over WebSocket", [
						{"Upgrade", "websocket"},
						{"Connection", "Upgrade"},
						{"Sec-WebSocket-Accept", ResponseKey},
						{"Sec-WebSocket-Protocol", "xmpp"}])}
	end,
	
	SockMod:send(Socket, Response),

	case Status of
		success ->
			{next_state, ws_session, State};
		failure ->
			SockMod:close(Socket),
			{stop, {error, Response}, State}
	end.

ws_session({recv, #ws_frame{opcode = ?WS_OPCODE_BINARY}}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	ClosingFrame = websocket_frame:make_close(?WS_CLOSE_UNSUPPORTED_DATA_TYPE,
		"XMPP over WebSocket forbid binary frames"),
	send_frame(SockMod, Socket, ClosingFrame),
	?WARNING_MSG("Got binary frame from client in XMPP over WebSocket session", []),
	{next_state, ws_closing, State};

ws_session({recv, #ws_frame{opcode = ?WS_OPCODE_TEXT} = Frame}, #ws_state{
		sockmod = SockMod,
		socket = Socket,
		request_headers = RequestHeaders,
		xmpp_ref = XmppRef
	} = State) ->
	PeerRet = case SockMod of
		gen_tcp ->
			inet:peername(Socket);
		_ ->
			SockMod:peername(Socket)
	end,
	IP = case PeerRet of
		{ok, IPHere} ->
			XFF = orddict_get("x-forwarded-for", RequestHeaders, []),
			[Host] = orddict_get("host", RequestHeaders, undefined),
			analyze_ip_xff(IPHere, XFF, Host);
		{error, _Error} ->
			undefined
	end,
	{_, _, NewXmppRef} = websocket_xmpp:process_request(
		SockMod,
		Socket,
		XmppRef,
		websocket_frame:get_payload(Frame),
		IP,
		self()),
	{next_state, ws_session, State#ws_state{
			xmpp_ref = NewXmppRef
		}};

ws_session({recv, #ws_frame{
		opcode = ?WS_OPCODE_CLOSE,
		payload_data = Data
	}}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	ClosingFrame = case Data of
		<<>> -> websocket_frame:make_close();
		<<Status:16, Message/binary>> -> websocket_frame:make_close(Status, Message)
	end,
	send_frame(SockMod, Socket, ClosingFrame),
	{next_state, closing, State};

ws_session({recv, #ws_frame{
		opcode = ?WS_OPCODE_PING,
		payload_data = Data
	}}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	PongFrame = websocket_frame:make_pong(Data),
	send_frame(SockMod, Socket, PongFrame),
	{next_state, ws_session, State};

ws_session({send, Data}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	Frame = websocket_frame:make(Data),
	send_frame(SockMod, Socket, Frame),
	{next_state, ws_session, State};

ws_session(close, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	ClosingFrame = websocket_frame:make_close(),
	send_frame(SockMod, Socket, ClosingFrame),
	{next_state, ws_closing, State};

ws_session({close, Code, Reason}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	ClosingFrame = websocket_frame:make_close(Code, Reason),
	send_frame(SockMod, Socket, ClosingFrame),
	{next_state, ws_closing, State}.

ws_closing({recv, #ws_frame{opcode = ?WS_OPCODE_CLOSE}}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	SockMod:close(Socket),
	{stop, normal, State}.


%-------------------------------------------------------------------------------
% Internal functions
%-------------------------------------------------------------------------------

-spec setopts(atom(), term(), [{atom(), term()}]) -> ok | {error, term()}.
setopts(SockMod, Socket, Opts) ->
	?DEBUG("setopts(~p, ~p, ~p)", [SockMod, Socket, Opts]),
	case SockMod of
		gen_tcp -> inet:setopts(Socket, Opts);
		_ -> SockMod:setopts(Socket, Opts)
	end.

-spec send_frame(atom(), term(), websocket_frame:frame()) -> ok | {error, term()}.
send_frame(SockMod, Socket, Frame) ->
	FrameBin = websocket_frame:to_binary(Frame),
	Result = SockMod:send(Socket, FrameBin),
	case Result of
		ok -> skip;
		{error, Reason} -> ?WARNING_MSG("Can't send fame ~p to websocket because of ~p", [Frame, Reason])
	end,
	Result.

-spec add_header(atom() | iodata(), iodata(), orddict:orddict()) -> orddict:orddict().
add_header(Name, Value, HeadersMap) ->
	BName = jlib:tolower(something_to_binary(Name)),
	Old = orddict_get(BName, HeadersMap, []),
	New = re:split(Value, ", ", [{return, list}]) ++ Old,
	orddict:store(BName, New ++ Old, HeadersMap).

-spec something_to_binary(atom | iodata()) -> binary().
something_to_binary(Something) ->
	case Something of
		%X when is_atom(X) -> atom_to_binary(X, latin1);
		X when is_atom(X) -> atom_to_list(X);
		X when is_binary(X) or is_list(X) -> binary_to_list(iolist_to_binary(X))
		%X when is_binary(X) or is_list(X) -> iolist_to_binary(X)
	end.

-spec build_http_response(
	{integer(), integer()}, integer(), iodata(), [{iodata(), iodata()}]) -> string().
build_http_response({VMaj, VMin}, Code, Message, Headers) ->
	VMajBin = list_to_binary(integer_to_list(VMaj)),
	VMinBin = list_to_binary(integer_to_list(VMin)),
	CodeBin = list_to_binary(integer_to_list(Code)),
	Response = binary_to_list(iolist_to_binary([
		"HTTP/", VMajBin, ".", VMinBin, " ", CodeBin, " ", Message, "\r\n",
		[[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
		"\r\n"])),
	?DEBUG("Sending response:~n~s", [Response]),
	Response.

-spec to_normalized_path(iodata()) -> [string()].
to_normalized_path(PList) when is_list(PList) ->
	case lists:all(fun is_integer/1, PList) of
		true ->  % String
			to_normalized_path(iolist_to_binary(PList));
		false ->  % General iolist
			[binary_to_list(iolist_to_binary(P)) || P <- PList]
	end;
to_normalized_path(PBin) when is_binary(PBin) ->
	RawPath = binary:split(PBin, <<$/>>, [global]),
	[binary_to_list(P) || P <- RawPath, byte_size(P) > 0].

-spec find_request_handler([{[binary()], atom()}], [binary()]) -> undefined | {atom(), [binary()]}.
find_request_handler([], _) ->
	undefined;
find_request_handler([{HandlerPathPrefix, HandlerModule} | HandlersLeft], Path) ->
	case (lists:prefix(HandlerPathPrefix, Path) or
			(HandlerPathPrefix == Path)) of
		true ->
			LocalPath = lists:nthtail(length(HandlerPathPrefix), Path),
			{HandlerModule, LocalPath};
		false ->
			find_request_handler(HandlersLeft, Path)
	end.

-spec websocket_transform_key(string()) -> string().
websocket_transform_key(Key) ->
	FullKey = Key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
	KeySha = crypto:hash(sha, FullKey),
	case byte_size(KeySha) of
		20 -> skip;
		Length -> ?WARNING_MSG("Invalid length of the key after applying sha-1: ~p", [Length])
	end,
	Result = jlib:encode_base64(binary_to_list(KeySha)),
	Result.

%% Support for X-Forwarded-From
analyze_ip_xff(IP, [], _Host) ->
	IP;
analyze_ip_xff({IPLast, Port}, XFF, Host) ->
	[ClientIP | ProxiesIPs] = XFF ++ [inet_parse:ntoa(IPLast)],
	TrustedProxies = case ejabberd_config:get_local_option({trusted_proxies, Host}, fun(X) -> X end) of
		undefined -> [];
		TPs -> TPs
	end,
	IPClient = case is_ipchain_trusted(ProxiesIPs, TrustedProxies) of
		true ->
			{ok, IPFirst} = inet_parse:address(ClientIP),
			?DEBUG("The IP ~w was replaced with ~w due to header "
				"X-Forwarded-For: ~s", [IPLast, IPFirst, XFF]),
			IPFirst;
		false ->
			IPLast
	end,
	{IPClient, Port}.

is_ipchain_trusted(_UserIPs, all) ->
	true;
is_ipchain_trusted(UserIPs, TrustedIPs) ->
	[] == UserIPs -- ["127.0.0.1" | TrustedIPs].

-spec orddict_get(term(), orddict:orddict(), term()) -> term().
orddict_get(Key, Orddict, Default) ->
	case orddict:find(Key, Orddict) of
		{ok, Value} -> Value;
		error -> Default
	end.

% Code below is taken (with some modifications) from the yaws webserver, which
% is distributed under the folowing license:
%
% This software (the yaws webserver) is free software.
% Parts of this software is Copyright (c) Claes Wikstrom <klacke@hyber.org>
% Any use or misuse of the source code is hereby freely allowed.
%
% 1. Redistributions of source code must retain the above copyright
%    notice as well as this list of conditions.
%
% 2. Redistributions in binary form must reproduce the above copyright
%    notice as well as this list of conditions.

url_decode_q_split(Path) ->
	url_decode_q_split(Path, []).
url_decode_q_split([$?|T], Ack) ->
	%% Don't decode the query string here, that is parsed separately.
	{path_norm_reverse(Ack), T};
url_decode_q_split([H|T], Ack) when H /= 0 ->
	url_decode_q_split(T, [H|Ack]);
url_decode_q_split([], Ack) ->
	{path_norm_reverse(Ack), []}.

%% @doc Decode a part of the URL and return string()
path_decode(Path) ->
	path_decode(Path, []).
path_decode([$%, Hi, Lo | Tail], Ack) ->
	Hex = hex_to_integer([Hi, Lo]),
	if Hex  == 0 -> exit(badurl);
		true -> ok
	end,
	path_decode(Tail, [Hex|Ack]);
path_decode([H|T], Ack) when H /= 0 ->
	path_decode(T, [H|Ack]);
path_decode([], Ack) ->
	lists:reverse(Ack).

path_norm_reverse("/" ++ T) -> start_dir(0, "/", T);
path_norm_reverse(       T) -> start_dir(0,  "", T).

start_dir(N, Path, ".."       ) -> rest_dir(N, Path, "");
start_dir(N, Path, "/"   ++ T ) -> start_dir(N    , Path, T);
start_dir(N, Path, "./"  ++ T ) -> start_dir(N    , Path, T);
start_dir(N, Path, "../" ++ T ) -> start_dir(N + 1, Path, T);
start_dir(N, Path,          T ) -> rest_dir (N    , Path, T).

rest_dir (_N, Path, []         ) -> case Path of
		[] -> "/";
		_  -> Path
	end;
rest_dir (0, Path, [ $/ | T ] ) -> start_dir(0    , [ $/ | Path ], T);
rest_dir (N, Path, [ $/ | T ] ) -> start_dir(N - 1,        Path  , T);
rest_dir (0, Path, [  H | T ] ) -> rest_dir (0    , [  H | Path ], T);
rest_dir (N, Path, [  _H | T ] ) -> rest_dir (N    ,        Path  , T).

%% hex_to_integer
hex_to_integer(Hex) ->
	case catch erlang:list_to_integer(Hex, 16) of
		{'EXIT', _} ->
			old_hex_to_integer(Hex);
		X ->
			X
	end.

old_hex_to_integer(Hex) ->
	DEHEX = fun (H) when H >= $a, H =< $f -> H - $a + 10;
		(H) when H >= $A, H =< $F -> H - $A + 10;
		(H) when H >= $0, H =< $9 -> H - $0
	end,
	lists:foldl(fun(E, Acc) -> Acc*16+DEHEX(E) end, 0, Hex).
