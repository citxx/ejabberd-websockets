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
		close/2
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
		ws_handshake_request/2,
		ws_handshake_header/2,
		ws_session/2
	]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("websocket_session.hrl").

%% record used to keep track of listener state
-record(state, {sockmod,
		socket,
		request_method,
		request_version,
		request_path,
		request_auth,
		request_keepalive,
		request_content_length,
		request_lang = "en",
		request_handlers = [],
		request_host,
		request_port,
		request_tp,
		request_headers = [],
		end_of_request = false,
		partial = <<>>,
		websocket_pid,
		trail = ""
	}).

-type process_reference() :: atom() | {atom(), atom()} | {global, term()} | pid().
-type request_handler() :: {list(binary()), atom()}.

%% record used to keep WebSocket session state
-record(ws_state, {
		sockmod :: atom(),
		socket :: inet:socket(),
		request_handlers = [] :: list(request_handler()),
		request_method = undefined :: undefined | atom() | binary(),
		request_version = undefined :: undefined | {integer(), integer()},
		request_path = undefined :: undefined | {abs_path, binary()} | binary(),
		request_headers = #{} :: map(),
		parsing_state = websocket_frame:new_parsing_state() ::
			websocket_frame:parsing_state(),
		xmpp_ref = undefined
	}).

%-------------------------------------------------------------------------------
% API
%-------------------------------------------------------------------------------

start_link(SockData, Opts) ->
	gen_fsm:start_link(?MODULE, [SockData, Opts], []).


-spec send(process_reference(), iodata()) -> ok.
send(WsSessionRef, Message) ->
	gen_fsm:send_event(WsSessionRef, {send, Message}).

-spec close(process_reference(), term()) -> ok.
close(WsSessionRef, Reason) ->
	gen_fsm:send_event(WsSessionRef, {close, Reason}).


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
	TLSEnabled = lists:member(tls, Opts),
	TLSOpts1 = [Opt || {certfile, _} = Opt <- Opts],
	TLSOpts = [verify_none | TLSOpts1],

	{SockMod1, Socket1} = case TLSEnabled of
		true ->
			inet:setopts(Socket, [{recbuf, 8192}]),
			{ok, TLSSocket} = tls:tcp_to_tls(Socket, TLSOpts),
			{tls, TLSSocket};
		false ->
			{SockMod, Socket}
	end,

	case SockMod1 of
		gen_tcp ->
			inet:setopts(Socket1, [{packet, http}, {recbuf, 8192}]);
		_ ->
			skip
	end,

	inet:setopts(Socket1, [{active, once}]),

	RequestHandlers = case lists:keysearch(request_handlers, 1, Opts) of
		{value, {request_handlers, H}} -> H;
		false -> []
	end,

	?INFO_MSG("started: ~p", [{SockMod1, Socket1}]),
	State = #ws_state{sockmod = SockMod1,
		socket = Socket1,
		request_handlers = RequestHandlers},
	{ok, ws_handshake_request, State}.

terminate(Reason, StateName, State) ->
	?DEBUG("~p:terminate(~p, ~p, map)", [?MODULE, Reason, StateName]),
	ok.

% TODO: add tls support
handle_info({_Type, Socket, Data}, StateName, State) ->
	?DEBUG("Recieved raw data: ~p", [Data]),
	SwitchToRaw = case Data of
		http_eoh -> [{packet, raw}];
		_ -> []
	end,
	inet:setopts(Socket, [{active, once} | SwitchToRaw]),
	apply(?MODULE, StateName, [{recv, Data}, State]);

% TODO: proper tcp_closed handling
handle_info({tcp_closed, _Socket}, _StateName, State) ->
	{stop, normal, State}.

% TODO: add tcp_error handling

ws_handshake_request(
		{recv, {http_request, Method, Uri, Version}},
		#ws_state{} = State) ->
	% TODO: error handling
	{abs_path, RawPath} = case Uri of
		{absoluteURI, _Scheme, _Host, _Port, P} -> {abs_path, P};
		_ -> Uri
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

% TODO: properly handle
ws_handshake_request(Event, State) ->
	?WARNING_MSG(
		"Unexpected event received in state ws_handshake_request:~n"
		"  Event = ~p~n"
		"  State = ~p~n",
		[Event, State]),
	{stop, normal, State}.
	
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
	Host = maps:get(<<"host">>, Headers, []),
	Upgrade = [jlib:tolower(X) || X <- maps:get(<<"upgrade">>, Headers, [])],
	Connection = [jlib:tolower(X) || X <- maps:get(<<"connection">>, Headers, [])],
	SecWebSocketKey = maps:get(<<"sec-websocket-key">>, Headers, []),
	?DEBUG("SecWebSocketKey = ~p of ~p", [SecWebSocketKey, 1]),
	SecWebSocketVersion = maps:get(<<"sec-websocket-version">>, Headers, []),
	SecWebSocketProtocol = maps:get(<<"sec-websocket-protocol">>, Headers, []),
	
	UpgradeContainsWebsocket = lists:member(<<"websocket">>, Upgrade),
	ConnectionContainsUpgrade = lists:member(<<"upgrade">>, Connection),
	ProtocolContainsXmpp = lists:member(<<"xmpp">>, SecWebSocketProtocol),
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
		SecWebSocketVersion =/= [<<"13">>] -> 
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
						{<<"Upgrade">>, <<"websocket">>},
						{<<"Connection">>, <<"Upgrade">>},
						{<<"Sec-WebSocket-Accept">>, ResponseKey},
						{<<"Sec-WebSocket-Protocol">>, <<"xmpp">>}])}
	end,
	
	SockMod:send(Socket, Response),

	{next_state, ws_session, State}.

% TODO: add request handlers support
% TODO: validate origin
ws_session({recv, Data}, #ws_state{
		parsing_state = ParsingState,
		xmpp_ref = XmppRef
	} = State) ->
	{Frames, NewParsingState} = websocket_frame:parse_stream(ParsingState, Data),
	NewXmppRef = lists:foldl(fun(Frame, Ref) ->
				process_frame(Frame, Ref, State)
		end, XmppRef, Frames),
	{next_state, ws_session, State#ws_state{
			parsing_state = NewParsingState,
			xmpp_ref = NewXmppRef
		}};

ws_session({send, Data}, #ws_state{
		sockmod = SockMod,
		socket = Socket
	} = State) ->
	Frame = websocket_frame:make(Data),
	FrameBin = websocket_frame:to_binary(Frame),
	SockMod:send(Socket, FrameBin),
	{next_state, ws_session, State};

ws_session({close, Reason}, #ws_state{
	} = State) ->
	ok.


%-------------------------------------------------------------------------------
% Internal functions
%-------------------------------------------------------------------------------

-spec process_frame(websocket_frame:frame(), process_reference()) ->
	process_reference().
process_frame(Frame, Ref, #ws_state{
		sockmod = SockMod,
		socket = Socket,
		request_headers = RequestHeaders
	} = _State) ->
	PeerRet = case SockMod of
		gen_tcp ->
			inet:peername(Socket);
		_ ->
			SockMod:peername(Socket)
	end,
	IP = case PeerRet of
		{ok, IPHere} ->
			XFF = case RequestHeaders of
				#{<<"x-forwarded-for">> := Value} -> Value;
				_ -> []
			end,
			#{<<"host">> := [Host]} = RequestHeaders,
			analyze_ip_xff(IPHere, XFF, Host);
		{error, _Error} ->
			undefined
	end,
	{_, _, NewRef} = websocket_xmpp:process_request(
		SockMod,
		Socket,
		Ref,
		websocket_frame:get_payload(Frame),
		IP,
		self()),
	NewRef.


-spec add_header(atom() | iodata(), iodata(), map()) -> map().
add_header(Name, Value, HeadersMap) ->
	BName = jlib:tolower(something_to_binary(Name)),
	Old = maps:get(BName, HeadersMap, []),
	New = re:split(Value, ", ", [{return, binary}]) ++ Old,
	maps:put(BName, New ++ Old, HeadersMap).

-spec something_to_binary(atom | iodata()) -> binary().
something_to_binary(Something) ->
	case Something of
		X when is_atom(X) -> atom_to_binary(X, latin1);
		X when is_binary(X) or is_list(X) -> iolist_to_binary(X)
	end.

-spec build_http_response(
	{integer(), integer()}, integer(), iodata(), [{iodata(), iodata()}]) -> binary().
build_http_response({VMaj, VMin}, Code, Message, Headers) ->
	VMajBin = integer_to_binary(VMaj),
	VMinBin = integer_to_binary(VMin),
	CodeBin = integer_to_binary(Code),
	Response = iolist_to_binary([
		"HTTP/", VMajBin, ".", VMinBin, " ", CodeBin, " ", Message, "\r\n",
		[[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
		"\r\n"]),
	?DEBUG("Sending response:~n~s", [Response]),
	Response.

-spec to_normalized_path(iolist()) -> binary().
to_normalized_path(PList) when is_list(PList) ->
	case lists:all(fun is_integer/1, PList) of
		true ->  % String
			to_normalized_path(iolist_to_binary(PList));
		false ->  % General iolist
			[iolist_to_binary(P) || P <- PList]
	end;
to_normalized_path(PBin) when is_binary(PBin) ->
	RawPath = binary:split(PBin, <<$/>>, [global]),
	[P || P <- RawPath, byte_size(P) > 0].

recv(SockMod, Socket, Length, Timeout) ->
	Result = SockMod:recv(Socket, Length, Timeout),
	?DEBUG("RECV(~p, ~p, ~p): ~p", [SockMod, Length, Timeout, Result]),
	Result.

receive_headers(#state{sockmod = SockMod, socket = Socket} = State) ->
	%Data = SockMod:recv(Socket, 0, 300000),
	Data = recv(SockMod, Socket, 0, 300000),
	case State#state.sockmod of
		gen_tcp ->
			NewState = process_header(State, Data),
			case NewState#state.end_of_request of
				true ->
					ok;
				_ ->
					receive_headers(NewState)
			end;
		_ ->
			case Data of
				{ok, Binary} ->
					?DEBUG("not gen_tcp, ssl? ~p~n", [Binary]),
					{Request, Trail} = parse_request(
						State,
						State#state.trail ++
						binary_to_list(Binary)),
					State1 = State#state{trail = Trail},
					NewState = lists:foldl(
						fun(D, S) ->
								case S#state.end_of_request of
									true ->
										S;
									_ ->
										process_header(S, D)
								end
						end, State1, Request),
					case NewState#state.end_of_request of
						true ->
							ok;
						_ ->
							receive_headers(NewState)
					end;
				Req ->
					?DEBUG("not gen_tcp or ok: ~p~n", [Req]),
					ok
			end
	end.

process_header(State, Data) ->
	%?WARNING_MSG("ejabberd_websocket:process_header(~p, ~p)", [State, Data]),
	case Data of
		{ok, {http_request, Method, Uri, Version}} ->
			KeepAlive = case Version of
				{1, 1} ->
					true;
				_ ->
					false
			end,
			Path = case Uri of
				{absoluteURI, _Scheme, _Host, _Port, P} -> {abs_path, P};
				_ -> Uri
			end,
			State#state{request_method = Method,
				request_version = Version,
				request_path = Path,
				request_keepalive = KeepAlive};
		{ok, {http_header, _, 'Connection'=Name, _, Conn}} ->
			KeepAlive1 = case jlib:tolower(iolist_to_binary(Conn)) of
				<<"keep-alive">> ->
					true;
				<<"close">> ->
					false;
				_ ->
					State#state.request_keepalive
			end,
			State#state{request_keepalive = KeepAlive1,
				request_headers=add_header(Name, Conn, State)};
		{ok, {http_header, _, 'Content-Length'=Name, _, SLen}} ->
			case catch list_to_integer(SLen) of
				Len when is_integer(Len) ->
					State#state{request_content_length = Len,
						request_headers=add_header(Name, SLen, State)};
				_ ->
					State
			end;
		{ok, {http_header, _, 'Host'=Name, _, Host}} ->
			State#state{request_host = Host,
				request_headers=add_header(Name, Host, State)};
		{ok, {http_header, _, Name, _, Value}} ->
			State#state{request_headers=add_header(Name, Value, State)};
		{ok, http_eoh} when State#state.request_host == undefined ->
			?WARNING_MSG("An HTTP request without 'Host' HTTP header was received.", []),
			throw(http_request_no_host_header);
		{ok, http_eoh} ->
			?DEBUG("(~w) http query: ~w ~s~n",
				[State#state.socket,
					State#state.request_method,
					element(2, State#state.request_path)]),
			Out = process_request(State),
			%% Test for web socket
			case (Out =/= undefined) and is_websocket_upgrade(State#state.request_headers) of
				true ->
					?DEBUG("Websocket!",[]),
					SockMod = State#state.sockmod,
					Socket = State#state.socket,
					case SockMod of
						gen_tcp ->
							inet:setopts(Socket, [{packet, raw}]);
						_ ->
							ok
					end,
					%% handle hand shake
					case handshake(State) of
						true ->
							case sub_protocol(State#state.request_headers) of
								"xmpp" ->
									%% send the state back
									#state{sockmod = SockMod,
										socket = Socket,
										request_handlers = State#state.request_handlers};
								_ ->
									?DEBUG("Bad sub protocol",[]),
									#state{end_of_request = true,
										request_handlers = State#state.request_handlers}
							end;
						_ ->
							?DEBUG("Bad Handshake",[]),
							#state{end_of_request = true,
								request_handlers = State#state.request_handlers}
					end;
				_ ->
					?DEBUG("Regular HTTP",[]),
					#state{end_of_request = true,
						request_handlers = State#state.request_handlers}
			end;
		{error, closed} ->
			?ERROR_MSG("Socket closed", [State]),
			process_data(State, socket_closed),
			#state{end_of_request = true,
				request_handlers = State#state.request_handlers};
		{error, timeout} ->
			?DEBUG("Socket recv timed out. Return the same State.",[]),
			State;
		{ok, HData} ->
			PData = case State#state.partial of
				<<>> ->
					HData;
				<<X/binary>> ->
					<<X, HData>>
			end,
			{_Out, Partial, Pid} = case process_data(State, PData) of
				{O, P} ->
					{O, P, false};
				{Output, Part, ProcId} ->
					{Output, Part, ProcId};
				Error ->
					?DEBUG("PROCESS DATA: error returned:~n~n~p~n", [Error]),
					{Error, undefined, undefined}
			end,
			?DEBUG("C2SPid:~p~n",[Pid]),
			case Pid of
				false ->
					#state{sockmod = State#state.sockmod,
						socket = State#state.socket,
						partial = Partial,
						request_handlers = State#state.request_handlers};
				_ ->
					#state{sockmod = State#state.sockmod,
						socket = State#state.socket,
						partial = Partial,
						websocket_pid = Pid,
						request_handlers = State#state.request_handlers}
			end;
		_ ->
			?DEBUG("Not expected: ~p~n",[Data]),
			#state{end_of_request = true,
				request_handlers = State#state.request_handlers}
	end.

is_websocket_upgrade(RequestHeaders) ->
	?WARNING_MSG("ejabberd_websocket:is_websocket_upgrade(~p)", [RequestHeaders]),
	Connection = case lists:keyfind('Connection', 1, RequestHeaders) of
		{'Connection', Up} -> jlib:tolower(iolist_to_binary(Up)) == <<"upgrade">>;
		_ -> false
	end,
	Upgrade = case lists:keyfind('Upgrade', 1, RequestHeaders) of
		{'Upgrade', UpTo} -> jlib:tolower(iolist_to_binary(UpTo)) == <<"websocket">>;
		_ -> false
	end,
	?DEBUG("IS WEBSOCKET UPGRADE: Connection = ~p, Upgrade = ~p", [Connection, Upgrade]),
	Connection and Upgrade.

handshake(State) ->
	%{_, Host} = lists:keyfind('Host', 1, State#state.request_headers),
	%{_, Origin} = lists:keyfind("Origin", 1, State#state.request_headers),
	SubProtocol = case lists:keyfind("Sec-Websocket-Protocol", 1, State#state.request_headers) of
		{"Sec-Websocket-Protocol", P} -> P;
		_ -> undefined
	end,
	{_, Key} = lists:keyfind("Sec-Websocket-Key", 1, State#state.request_headers),
	{_, Version} = lists:keyfind("Sec-Websocket-Version", 1, State#state.request_headers),
	case Version of
		"13" ->
			ResponseKey = websocket_transform_key(iolist_to_binary(Key)),
			%% Build response
			Res = build_handshake_response(ResponseKey, SubProtocol),
			?DEBUG("Sending handshake response:~p~n",[Res]),
			%% send response
			case send_text(State, Res) of
				ok -> true;
				E ->
					?DEBUG("ERROR Sending text:~p~n",[E]),
					false
			end;
		V -> ?WARNING_MSG("Try to connect with unsupported websocket version: ~s", [V])
	end.

process_data(State, Data) ->
	SockMod = State#state.sockmod,
	Socket = State#state.socket,
	RequestHeaders = State#state.request_headers,
	Host = State#state.request_host,
	Path = case State#state.request_path of
		undefined -> ["ws-xmpp"];
		X -> X
	end,
	PeerRet = case SockMod of
		gen_tcp ->
			inet:peername(Socket);
		_ ->
			SockMod:peername(Socket)
	end,
	IP = case PeerRet of
		{ok, IPHere} ->
			XFF = proplists:get_value('X-Forwarded-For',
				RequestHeaders, []),
			analyze_ip_xff(IPHere, XFF, Host);
		{error, _Error} ->
			undefined
	end,
	Request = #wsrequest{method = State#state.request_method,
		path = to_normalized_path(Path),
		headers = State#state.request_headers,
		data = Data,
		fsmref = State#state.websocket_pid,
		wsocket = Socket,
		wsockmod = SockMod,
		ip = IP
	},
	process(State#state.request_handlers, Request).

process_request(#state{request_method = Method,
		request_path = {abs_path, Path},
		request_handlers = RequestHandlers,
		request_headers = RequestHeaders,
		sockmod = SockMod,
		socket = Socket
	} = State) when Method=:='GET' ->
	case (catch url_decode_q_split(Path)) of
		{'EXIT', _} ->
			process_request(false);
		{NPath, _Query} ->
			%% Build Request
			LPath = [path_decode(NPE) || NPE <- string:tokens(NPath,
					"/")],
			Request = #wsrequest{method = Method,
				path = to_normalized_path(LPath),
				headers = RequestHeaders,
				wsocket = Socket,
				wsockmod = SockMod
			},
			?INFO_MSG("Processing request:~p:~p~n",[Request, State]),
			%process(RequestHandlers, Request)
			find_request_handler(RequestHandlers, Request#wsrequest.path)
	end;
process_request(State) ->
	?DEBUG("Not a handshake: ~p~n", [State]),
	false.

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

process(RequestHandlers, Request) ->
	?DEBUG("PROCESS(~p, ~p): ~p", [RequestHandlers, Request, process_info(self(), current_stacktrace)]),
	?DEBUG("PROCESS: frh(~p, ~p) = ~p", [RequestHandlers, Request#wsrequest.path, find_request_handler(RequestHandlers, Request#wsrequest.path)]),
	case find_request_handler(RequestHandlers, Request#wsrequest.path) of
		{HandlerModule, LocalPath} ->
			HandlerModule:process(LocalPath, Request);
		undefined ->
			false
	end.

%% send data
send_text(State, Text) ->
	case catch (State#state.sockmod):send(State#state.socket, Text) of
		ok -> ok;
		{error, timeout} ->
			?INFO_MSG("Timeout on ~p:send",[State#state.sockmod]),
			exit(normal);
		Error ->
			?DEBUG("Error in ~p:send: ~p",[State#state.sockmod, Error]),
			exit(normal)
	end.

-spec websocket_transform_key(binary()) -> binary().
websocket_transform_key(Key) ->
	FullKey = <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
	KeySha = crypto:hash(sha, FullKey),
	case byte_size(KeySha) of
		20 -> skip;
		Length -> ?WARNING_MSG("Invalid length of the key after applying sha-1: ~p", [Length])
	end,
	Result = jlib:encode_base64(KeySha),
	Result.

%% build the handshake response
build_handshake_response(ResponseKey, SubProtocol) ->
	SubProtocolHeader = case SubProtocol of
		undefined -> "";
		P -> ["Sec-WebSocket-Protocol: ", P, "\r\n"]
	end,
	Response = iolist_to_binary([
		"HTTP/1.1 101 Switching protocol to XMPP over WebSocket\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Accept: ", ResponseKey, "\r\n",
		SubProtocolHeader,
		"\r\n"]),
	?DEBUG("WebSocket: response to handshake with:~n~n~s~n~n", [Response]),
	Response.

sub_protocol(Headers) ->
	SubProtocol = case lists:keyfind("Sec-WebSocket-Protocol", 1, Headers) of
		{"Sec-WebSocket-Protocol", SubP} -> SubP;
		_ -> "xmpp"
	end,
	SubProtocol.

%% Support for X-Forwarded-From
analyze_ip_xff(IP, [], _Host) ->
	IP;
analyze_ip_xff({IPLast, Port}, XFF, Host) ->
	[ClientIP | ProxiesIPs] = XFF
	++ [inet_parse:ntoa(IPLast)],
	TrustedProxies = case ejabberd_config:get_local_option(
			{trusted_proxies, Host}) of
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

% The following code is mostly taken from yaws_ssl.erl

parse_request(State, Data) ->
	case Data of
		[] ->
			{[], []};
		_ ->
			?DEBUG("GOT ssl data ~p~n", [Data]),
			{R, Trail} = case State#state.request_method of
				undefined ->
					{R1, Trail1} = get_req(Data),
					?DEBUG("Parsed request ~p~n", [R1]),
					{[R1], Trail1};
				_ ->
					{[], Data}
			end,
			{H, Trail2} = get_headers(Trail),
			{R ++ H, Trail2}
	end.

get_req("\r\n\r\n" ++ _) ->
	bad_request;
get_req("\r\n" ++ Data) ->
	get_req(Data);
get_req(Data) ->
	{FirstLine, Trail} = lists:splitwith(fun not_eol/1, Data),
	R = parse_req(FirstLine),
	{R, Trail}.


not_eol($\r)->
	false;
not_eol($\n) ->
	false;
not_eol(_) ->
	true.


get_word(Line)->
	{Word, T} = lists:splitwith(fun(X)-> X /= $\  end, Line),
	{Word, lists:dropwhile(fun(X) -> X == $\  end, T)}.


parse_req(Line) ->
	{MethodStr, L1} = get_word(Line),
	?DEBUG("Method: ~p~n", [MethodStr]),
	case L1 of
		[] ->
			bad_request;
		_ ->
			{URI, L2} = get_word(L1),
			{VersionStr, L3} = get_word(L2),
			?DEBUG("URI: ~p~nVersion: ~p~nL3: ~p~n",
				[URI, VersionStr, L3]),
			case L3 of
				[] ->
					Method = case MethodStr of
						"GET" -> 'GET';
						"POST" -> 'POST';
						"HEAD" -> 'HEAD';
						"OPTIONS" -> 'OPTIONS';
						"TRACE" -> 'TRACE';
						"PUT" -> 'PUT';
						"DELETE" -> 'DELETE';
						S -> S
					end,
					Path = case URI of
						"*" ->
							% Is this correct?
							"*";
						_ ->
							case string:str(URI, "://") of
								0 ->
									% Relative URI
									% ex: /index.html
									{abs_path, URI};
								N ->
									% Absolute URI
									% ex: http://localhost/index.html

									% Remove scheme
									% ex: URI2 = localhost/index.html
									URI2 = string:substr(URI, N + 3),
									% Look for the start of the path
									% (or the lack of a path thereof)
									case string:chr(URI2, $/) of
										0 -> {abs_path, "/"};
										M -> {abs_path,
												string:substr(URI2, M + 1)}
									end
							end
					end,
					case VersionStr of
						[] ->
							{ok, {http_request, Method, Path, {0,9}}};
						"HTTP/1.0" ->
							{ok, {http_request, Method, Path, {1,0}}};
						"HTTP/1.1" ->
							{ok, {http_request, Method, Path, {1,1}}};
						_ ->
							bad_request
					end;
				_ ->
					bad_request
			end
	end.


get_headers(Tail) ->
	get_headers([], Tail).

get_headers(H, Tail) ->
	case get_line(Tail) of
		{incomplete, Tail2} ->
			{H, Tail2};
		{line, Line, Tail2} ->
			get_headers(H ++ parse_line(Line), Tail2);
		{lastline, Line, Tail2} ->
			{H ++ parse_line(Line) ++ [{ok, http_eoh}], Tail2}
	end.


parse_line("Connection:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Connection', undefined, strip_spaces(Con)}}];
parse_line("Host:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Host', undefined, strip_spaces(Con)}}];
parse_line("Accept:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Accept', undefined, strip_spaces(Con)}}];
parse_line("If-Modified-Since:" ++ Con) ->
	[{ok, {http_header,  undefined, 'If-Modified-Since', undefined, strip_spaces(Con)}}];
parse_line("If-Match:" ++ Con) ->
	[{ok, {http_header,  undefined, 'If-Match', undefined, strip_spaces(Con)}}];
parse_line("If-None-Match:" ++ Con) ->
	[{ok, {http_header,  undefined, 'If-None-Match', undefined, strip_spaces(Con)}}];
parse_line("If-Range:" ++ Con) ->
	[{ok, {http_header,  undefined, 'If-Range', undefined, strip_spaces(Con)}}];
parse_line("If-Unmodified-Since:" ++ Con) ->
	[{ok, {http_header,  undefined, 'If-Unmodified-Since', undefined, strip_spaces(Con)}}];
parse_line("Range:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Range', undefined, strip_spaces(Con)}}];
parse_line("User-Agent:" ++ Con) ->
	[{ok, {http_header,  undefined, 'User-Agent', undefined, strip_spaces(Con)}}];
parse_line("Accept-Ranges:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Accept-Ranges', undefined, strip_spaces(Con)}}];
parse_line("Authorization:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Authorization', undefined, strip_spaces(Con)}}];
parse_line("Keep-Alive:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Keep-Alive', undefined, strip_spaces(Con)}}];
parse_line("Referer:" ++ Con) ->
	[{ok, {http_header,  undefined, 'Referer', undefined, strip_spaces(Con)}}];
parse_line("Content-type:"++Con) ->
	[{ok, {http_header,  undefined, 'Content-Type', undefined, strip_spaces(Con)}}];
parse_line("Content-Type:"++Con) ->
	[{ok, {http_header,  undefined, 'Content-Type', undefined, strip_spaces(Con)}}];
parse_line("Content-Length:"++Con) ->
	[{ok, {http_header,  undefined, 'Content-Length', undefined, strip_spaces(Con)}}];
parse_line("Content-length:"++Con) ->
	[{ok, {http_header,  undefined, 'Content-Length', undefined, strip_spaces(Con)}}];
parse_line("Cookie:"++Con) ->
	[{ok, {http_header,  undefined, 'Cookie', undefined, strip_spaces(Con)}}];
parse_line("Accept-Language:"++Con) ->
	[{ok, {http_header,  undefined, 'Accept-Language', undefined, strip_spaces(Con)}}];
parse_line("Accept-Encoding:"++Con) ->
	[{ok, {http_header,  undefined, 'Accept-Encoding', undefined, strip_spaces(Con)}}];
parse_line(S) ->
	case lists:splitwith(fun(C)->C /= $: end, S) of
		{Name, [$:|Val]} ->
			[{ok, {http_header,  undefined, Name, undefined, strip_spaces(Val)}}];
		_ ->
			[]
	end.


is_space($\s) ->
	true;
is_space($\r) ->
	true;
is_space($\n) ->
	true;
is_space($\t) ->
	true;
is_space(_) ->
	false.


strip_spaces(String) ->
	strip_spaces(String, both).

strip_spaces(String, left) ->
	drop_spaces(String);
strip_spaces(String, right) ->
	lists:reverse(drop_spaces(lists:reverse(String)));
strip_spaces(String, both) ->
	strip_spaces(drop_spaces(String), right).

drop_spaces([]) ->
	[];
drop_spaces(YS=[X|XS]) ->
	case is_space(X) of
		true ->
			drop_spaces(XS);
		false ->
			YS
	end.

is_nb_space(X) ->
	lists:member(X, [$\s, $\t]).


% ret: {line, Line, Trail} | {lastline, Line, Trail}

get_line(L) ->
	get_line(L, []).
get_line("\r\n\r\n" ++ Tail, Cur) ->
	{lastline, lists:reverse(Cur), Tail};
get_line("\r\n" ++ Tail, Cur) ->
	case Tail of
		[] ->
			{incomplete, lists:reverse(Cur) ++ "\r\n"};
		_ ->
			case is_nb_space(hd(Tail)) of
				true ->  %% multiline ... continue
		get_line(Tail, [$\n, $\r | Cur]);
	false ->
		{line, lists:reverse(Cur), Tail}
end
		end;
	get_line([H|T], Cur) ->
		get_line(T, [H|Cur]).