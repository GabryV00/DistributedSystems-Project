-module(p2p_tcp).
-export([start/0, loop/2]).

-include_lib("./records.hrl").

start() ->
    {ok, ListenSocket} = gen_tcp:listen(9000, [binary, {packet, 0},
                                        {active, false}]),
    loop(ListenSocket, 1).

loop(ListenSocket, ConnNumber) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    io:format("starting connection ~p~n", [ConnNumber]),
    spawn(fun() -> handle_request(Socket, ConnNumber) end),
    loop(ListenSocket, ConnNumber+1).

handle_request(Socket, ConnNumber) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            % Process the received data
            Response = <<"ACK">>,
            process_data(Data),
            gen_tcp:send(Socket, Response),
            % gen_tcp:close(Socket);
            handle_request(Socket, ConnNumber);
        {error, closed} ->
            io:format("Connection closed by other side");
        {error, Reason} ->
            io:format("Error receiving data: ~p~n", [Reason])
    end.

process_data(Data) ->
    try
        Command = jsone:decode(Data),
        case maps:get(<<"type">>, Command) of
            <<"req_con">> ->
                From = get_pid_from_id(maps:get(<<"idA">>, Command)),
                To = get_pid_from_id(maps:get(<<"idB">>, Command)),
                Band = maps:get(<<"band">>, Command), % number
                p2p_node:request_to_communicate(From, To, Band);
            <<"new_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                Adjs = build_edges(Id, maps:get(<<"id">>, Command)),
                p2p_node:join(Id, Adjs);
            <<"rem_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                p2p_node:leave_network(Id)
        end
    catch
        error:_Error ->
            io:format("Data not in JSON format")
    end.



get_pid_from_id(Id) when is_number(Id)->
    list_to_atom("node" ++ integer_to_list(Id)).


build_edges(Src, Edges) when is_list(Edges)->
    lists:map(fun([Dst, Weight]) -> 
                #edge{src = get_pid_from_id(Src),
                      dst = get_pid_from_id(Dst),
                      weight = Weight}
              end, Edges).
