-module(socket_async).
-behavior(gen_server).

-include("ejabberd.hrl").

-record(socket_async_state, {
		receiver :: pid() | atom(),
		sockmod :: atom(),
		socket :: term(),
		rest = <<>> :: binary(),
		packet_type = raw :: atom()
	}).

-export([
		start/2,
		start_link/2,
		stop/1,
		active_once/1,
		set_packet_type/2
	]).

-export([
		init/1,
		handle_cast/2,
		handle_info/2,
		handle_call/3,
		terminate/2
	]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(SockMod, Socket) ->
	gen_server:start(?MODULE, [self(), SockMod, Socket], []).

start_link(SockMod, Socket) ->
	gen_server:start_link(?MODULE, [self(), SockMod, Socket], []).

stop(ServerRef) ->
	gen_server:stop(ServerRef).

active_once(ServerRef) ->
	gen_server:cast(ServerRef, {active, once}),
	ok.

set_packet_type(ServerRef, Type) ->
	gen_server:cast(ServerRef, {set_packet_type, Type}),
	ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([Receiver, SockMod, Socket]) ->
	{ok, #socket_async_state{
			receiver = Receiver,
			sockmod = SockMod,
			socket = Socket
		}}.

terminate(Reason, State) ->
	?DEBUG("socket_async terminated. Reason = ~p. State = ~p", [Reason, State]).

handle_cast({active, once} = Message, #socket_async_state{
		receiver = Receiver,
		sockmod = SockMod,
		socket = Socket,
		rest = Rest,
		packet_type = PacketType
	} = State) ->
	case erlang:decode_packet(PacketType, Rest, []) of
		{ok, Packet, NewRest} ->
			Receiver ! {PacketType, Socket, Packet},
			{noreply, State#socket_async_state{rest = NewRest}};
		{more, _Length} ->
			case SockMod:recv(Socket, 0) of
				{ok, Data} ->
					handle_cast(
						Message,
						State#socket_async_state{rest = <<Rest/binary, Data/binary>>}
					);
				{error, Reason} ->
					?DEBUG("socket_async: cannot read from socket because of ~p.~nState = ~p", [Reason, State]),
					{stop, normal, State}
			end;
		{error, Reason} ->
			?WARNING_MSG("socket_async: cannot decode packet because of ~p.~nState = ~p", [Reason, State]),
			{stop, Reason, State}
	end;

handle_cast({set_packet_type, Type}, State) ->
	{noreply, State#socket_async_state{packet_type = Type}}.

handle_call(Message, From, State) ->
	?WARNING_MSG("~p:handle_call: unexpected message recieved from ~p: ~p~nState = ~p", [?MODULE, From, Message, State]),
	{stop, {error, {unexpected_message, From, Message}}, State}.

handle_info(Message, State) ->
	?WARNING_MSG("~p:handle_info: unexpected message recieved: ~p~nState = ~p", [?MODULE, Message, State]),
	{stop, {error, {unexpected_message, Message}}, State}.
