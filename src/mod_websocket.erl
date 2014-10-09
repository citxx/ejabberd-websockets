%%%----------------------------------------------------------------------
%%% File    : mod_websocket.erl
%%% Author  : Nathan Zorn <nathan.zorn@gmail.com>
%%% Purpose : XMPP over websockets
%%%----------------------------------------------------------------------

-module(mod_websocket).
-author('nathan.zorn@gmail.com').

-define(MOD_WEBSOCKET_VERSION, "0.1").
-define(PROCNAME_MHB, ejabberd_mod_websocket).

-behaviour(gen_mod).

-export([
	start/2,
	stop/1
]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").


start(Host, _Opts) ->
		?WARNING_MSG("~p loaded on ~s", [?MODULE, Host]),
		case lists:keyfind(ssl, 1, application:which_applications()) of
			false -> ssl:start();
			_ -> skip
		end,
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
