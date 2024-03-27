-module(p2p_tcp).
-export([start_link/1, loop/2]).

-include_lib("./records.hrl").
-include_lib("kernel/include/logger.hrl").
-define(LOG_FILENAME, "logs/tcp.txt").

start_link(Port) ->
    Pid = spawn_link(fun() -> init(Port) end),
    {ok, Pid}.

init(Port) ->
    start_logger(),
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {packet, 0},
                                        {active, false}]),
    loop(ListenSocket, 1).

loop(ListenSocket, ConnNumber) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    logger_std_h:filesync(to_file_handler),
    ?LOG_INFO("starting connection ~p~n", [ConnNumber]),
    spawn(fun() -> handle_request(Socket, ConnNumber) end),
    loop(ListenSocket, ConnNumber+1).

handle_request(Socket, ConnNumber) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            % Process the received data
            Response = <<"ACK">>,
            process_data(Data),
            % gen_tcp:close(Socket);
            handle_request(Socket, ConnNumber),
            gen_tcp:send(Socket, Response);
        {error, closed} ->
            ?LOG_INFO("Connection closed by other side");
        {error, Reason} ->
            ?LOG_ERROR("Error receiving data: ~p~n", [Reason])
    end.

process_data(Data) ->
    Stripped = string:trim(Data),
    try
        Command = jsone:decode(Stripped),
        case maps:get(<<"type">>, Command) of
            <<"req_con">> ->
                From = get_pid_from_id(maps:get(<<"idA">>, Command)),
                To = get_pid_from_id(maps:get(<<"idB">>, Command)),
                Band = maps:get(<<"band">>, Command), % number
                p2p_node:request_to_communicate(From, To, Band),
                ?LOG_INFO("~p asked ~p to communicate with bandwidth ~p", [From, To, Band]);
            <<"new_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                Adjs = build_edges(Id, maps:get(<<"edges">>, Command)),
                p2p_node_sup:start_link(Id, Adjs),
                ?LOG_INFO("~p started with adjs ~p~n", [Id, Adjs]);
            <<"rem_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                p2p_node:leave_network(Id),
                ?LOG_INFO("~p left the network", [Id])
        end
    catch
        error:{badarg, _Stack} ->
            io:format("Data not in JSON format: ~p~n", [Data])
    end.



get_pid_from_id(Id) when is_number(Id)->
    list_to_atom("node" ++ integer_to_list(Id)).


build_edges(Src, Edges) when is_list(Edges)->
    lists:map(fun([Dst, Weight]) -> 
                #edge{src = get_pid_from_id(Src),
                      dst = get_pid_from_id(Dst),
                      weight = Weight}
              end, Edges).


start_logger() ->
    logger:set_module_level(?MODULE, debug),
    Config = #{
        config => #{
            file => ?LOG_FILENAME,
            % prevent flushing (delete)
            flush_qlen => 100000,
            % disable drop mode
            drop_mode_qlen => 100000,
            % disable burst detection
            burst_limit_enable => false
        },
        level => info,
        modes => [write],
        formatter => {logger_formatter, #{template => [pid, " ", msg, "\n"]}}
    },
    logger:add_handler(to_file_handler, logger_std_h, Config),
    logger:set_handler_config(default, level, notice),
    ?LOG_DEBUG("===== LOG START =====").

