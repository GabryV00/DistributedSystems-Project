-module(p2p_tcp).
-export([start_link/1]).

-include_lib("./records.hrl").
-include_lib("kernel/include/logger.hrl").
-define(LOG_FILENAME, "logs/tcp.txt").


%% @doc Starts the tcp server
%% @param Port is the port on which it will listen for requests
%% @end
start_link(Args) ->
    Pid = spawn_link(fun() -> init(Args) end),
    {ok, Pid}.

%% @private
%% @doc Setup function, starts the socket
%% @end
init([Port] = _Args) ->
    start_logger(),
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {packet, 0},
                                        {active, false}]),
    loop(ListenSocket).

%% @private
%% @doc Main function that implements the server, accepts requests and spawns
%% handlers
%% @param ListenSocket Opened socket, obtained with gen_tcp:listen
%% @end
loop(ListenSocket) -> loop(ListenSocket, 1).
loop(ListenSocket, ConnNumber) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    logger_std_h:filesync(to_file_handler),
    ?LOG_INFO("starting connection ~p~n", [ConnNumber]),
    spawn(fun() -> handle_request(Socket, ConnNumber) end),
    loop(ListenSocket, ConnNumber+1).

%% @private
%% @doc Request handler
%% @param Socket Listening socket obtained with gen_tcp:accept
%% @param ConnNumber Connection ID, mainly for logging purpose
%% @end
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

%% @private
%% @doc Request parser
%% @param Data The data received by the socket
%% @end
process_data(Data) ->
    % Get rid of trailing spaces/newlines
    Stripped = string:trim(Data),
    try
        Command = jsone:decode(Stripped),
        % Extract the type of action to be performed
        case maps:get(<<"type">>, Command) of
            % Request to communicate
            <<"req_con">> ->
                From = get_pid_from_id(maps:get(<<"idA">>, Command)),
                To = get_pid_from_id(maps:get(<<"idB">>, Command)),
                Band = maps:get(<<"band">>, Command), % number
                p2p_node:request_to_communicate(From, To, Band),
                ?LOG_INFO("~p asked ~p to communicate with bandwidth ~p", [From, To, Band]);
            % New peer added to the network
            <<"new_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                Adjs = build_edges(Id, maps:get(<<"edges">>, Command)),
                p2p_node_sup:start_link(Id, Adjs),
                ?LOG_INFO("~p started with adjs ~p~n", [Id, Adjs]);
            % Peer removed from the network
            <<"rem_peer">> ->
                Id = get_pid_from_id(maps:get(<<"id">>, Command)),
                p2p_node:leave_network(Id),
                ?LOG_INFO("~p left the network", [Id])
        end
    catch
        error:{badarg, _Stack} ->
            ?LOG_ERROR("Data not in JSON format: ~p~n", [Data]);
        error:Error ->
            ?LOG_ERROR("Error during data processing: ~p", [Error])
    end.

%% @private
%% @doc Transforms numeric ID into atom that represents the peer node
%% @end
get_pid_from_id(Id) when is_number(Id)->
    list_to_atom("node" ++ integer_to_list(Id)).


%% @private
%% @doc Transforms the edges from JSON into internal format
%% @param Src Is the node from which the edge goes out
%% @param Edges Are the outgoing edges in form [Dst, Weight]
%% @end
build_edges(Src, Edges) when is_list(Edges)->
    lists:map(fun([Dst, Weight]) ->
                #edge{src = get_pid_from_id(Src),
                      dst = get_pid_from_id(Dst),
                      weight = Weight}
              end, Edges).


%% @private
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

