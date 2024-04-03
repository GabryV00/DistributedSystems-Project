-module(p2p_conn_handler).
-export([start_link/0, talk_to/4, talk_to/5]).


start_link() ->
    Pid = spawn_link(fun() -> init() end),
    {ok, Pid}.

init() ->
    loop().

loop() ->
    receive
        _ ->
            loop()
    end.

talk_to(ConnHandlerPid, NextHop, Who, To) ->
    ok.
talk_to(ConnHandlerPid, NextHop, LastHop, Who, To) ->
    ok.
