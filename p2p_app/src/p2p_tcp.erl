-module(p2p_tcp).
-export([start_link/1]).

-include_lib("kernel/include/logger.hrl").

%% @doc Starts the tcp server
%% @param Port is the port on which it will listen for requests
%% @end
-spec start_link(Args :: term()) -> {ok, Pid :: pid()} | {error, Reason :: term()}.
start_link(Args) ->
    Pid = spawn_link(fun() -> init(Args) end),
    {ok, Pid}.

%% @private
%% @doc Setup function, starts the socket
%% @end
init([Port] = _Args) ->
    logger:set_module_level(?MODULE, debug),
    try
        {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {packet, 0},
                                            {active, false}]),
        loop(ListenSocket)
    catch
        error:{{badmatch, _} = Reason, _Stack} ->
            ?LOG_ERROR("(tcp) Could not start TCP socket because of ~p~n", [Reason])
    end.

%% @private
%% @doc Main function that implements the server, accepts requests and spawns
%% handlers
%% @param ListenSocket Opened socket, obtained with gen_tcp:listen
%% @end
loop(ListenSocket) -> loop(ListenSocket, 1).
loop(ListenSocket, ConnNumber) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    logger_std_h:filesync(to_file_handler),
    ?LOG_DEBUG("(tcp) starting connection ~p~n", [ConnNumber]),
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
            io:format("received request ~p~n", [Data]),
            Reply = process_data(Data),
            Response = process_reply(Reply),
            io:format("sending reply: ~p~n", [Response]),
            % gen_tcp:close(Socket);
            gen_tcp:send(Socket, Response),
            handle_request(Socket, ConnNumber);
        {error, closed} ->
            ?LOG_INFO("(tcp) Connection closed by other side");
        {error, Reason} ->
            ?LOG_ERROR("(tcp) Error receiving data: ~p~n", [Reason])
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
            <<"req_conn">> ->
                From = utils:get_pid_from_id(maps:get(<<"idA">>, Command)),
                To = utils:get_pid_from_id(maps:get(<<"idB">>, Command)),
                Band = list_to_integer(binary_to_list(maps:get(<<"band">>, Command))), % number
                io:format("band requested: ~p~n", [Band]),
                Reply = p2p_node:request_to_communicate(From, To, Band),
                ?LOG_DEBUG("(tcp) ~p asked ~p to communicate with bandwidth ~p", [From, To, Band]);
            % New peer added to the network
            <<"new_peer">> ->
                Id = utils:get_pid_from_id(maps:get(<<"id">>, Command)),
                Adjs = utils:build_edges(Id, maps:get(<<"edges">>, Command)),
                p2p_admin:spawn_node(Id, []),
                p2p_node:join_network(Id, Adjs),
                timer:sleep(100),
                Reply = p2p_node:start_mst_computation(Id),
                ?LOG_DEBUG("(tcp) ~p started with adjs ~p~n", [Id, Adjs]);
            % Peer removed from the network
            <<"rem_peer">> ->
                Id = utils:get_pid_from_id(maps:get(<<"id">>, Command)),
                Reply = p2p_node:leave_network(Id),
                ?LOG_DEBUG("(tcp) ~p left the network", [Id]);
            % Close the connection between two peers
            <<"close_conn">> ->
                From = utils:get_pid_from_id(maps:get(<<"idA">>, Command)),
                To = utils:get_pid_from_id(maps:get(<<"idB">>, Command)),
                Reply = p2p_node:close_connection(From, To),
                ?LOG_DEBUG("(tcp) Closed connection between ~p and ~p", [From, To]);
            <<"get_state">> ->
                Node = utils:get_pid_from_id(maps:get(<<"id">>, Command)),
                Reply = p2p_node:get_state(Node)
        end,
        Reply
    catch
        error:{badarg, _Stack} ->
            ?LOG_ERROR("(tcp) Data not in JSON format: ~p~n", [Data]);
        error:{Reason, Stack} ->
            ?LOG_ERROR("(tcp) Error:~p while processing: ~p ~p", [Reason, Data, Stack])
    end.


%% @private
%% @doc Formats replies to be sent to the other endpoint in JSON format
%% @end
process_reply(Reply) ->
    case Reply of
        ok ->
            jsone:encode(#{<<"outcome">> => <<"ok">>, <<"message">> => <<"THE REQUEST WAS SUCCESSFUL">>});
        {ok, Message} ->
            jsone:encode(#{<<"outcome">> => <<"ok">>, <<"message">> => Message});
        {Error, Message} ->
            jsone:encode(#{<<"outcome">> => <<"error">>, <<"message">> => {Error, Message}});
        Message ->
            jsone:encode(#{<<"outcome">> => <<"ok">>, <<"message">> => Message})
    end.
