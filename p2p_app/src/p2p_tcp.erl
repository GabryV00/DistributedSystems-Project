-module(p2p_tcp).
-export([start/0, loop/1]).

start() ->
    {ok, ListenSocket} = gen_tcp:listen(9000, [{active, false}]),
    loop(ListenSocket).

loop(ListenSocket) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    spawn(fun() -> handle_request(Socket) end),
    loop(ListenSocket).

handle_request(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            % Process the received data
            Response = <<"ACK">>,
            gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket);
        {error, Reason} ->
            io:format("Error receiving data: ~p~n", [Reason])
    end.

process_data(Data) ->
    % Do something with the received data
    % For example, echo it back
    Data.


