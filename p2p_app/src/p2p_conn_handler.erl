-module(p2p_conn_handler).
-export([start_link/0, talk_to/4, talk_to/5, send_data/2]).

-record(state, {
          conn_id :: {term(), term()},
          forward_hop :: pid(),
          backward_hop = none :: pid() | none, % none only for sender or receiver
          parent :: pid()
         }).

%%% API FUNCTIONS

%% @doc Starts the connection handler
%% @end
start_link() ->
    Pid = spawn_link(fun() -> init() end),
    {ok, Pid}.

%% @doc Tells the connection handler which is the next hop to forward the data to
%% @param ConnHandlerPid The pid of the connection handler
%% @param ForwardHop The pid of the connection handler to which to send the
%%  data in order to reach To
%% @param From The source peer
%% @param To The destination peer
%% @end
-spec talk_to(ConnHandlerPid :: pid(), ForwardHop :: pid(), From :: pid(), To :: pid()) -> ok.
talk_to(ConnHandlerPid, ForwardHop, From, To) ->
    ConnHandlerPid ! {change_config, ForwardHop, From, To}, ok.

%% @doc Same as talk_to/4, but also a backward hop is specified (to handle two-way communication)
%% @param ConnHandlerPid The pid of the connection handler
%% @param ForwardHop The pid of the connection handler to which to send the
%%  data in order to reach To
%% @param ForwardHop The pid of the connection handler to which to send the
%%  data in order to reach From
%% @param From The source peer
%% @param To The destination peer
%% @end
-spec talk_to(ConnHandlerPid :: pid(), ForwardHop :: pid(), BackwardHop :: pid(), From :: pid(), To :: pid()) -> ok.
talk_to(ConnHandlerPid, ForwardHop, BackwardHop, From, To) ->
    ConnHandlerPid ! {change_config, {ForwardHop, BackwardHop, From, To}}, ok.

%% @doc Send data with a specific connection handler (which is bound to a single communication)
%% @param ConnHandlerPid The pid of the connection handler
%% @param Data Binary data to send
%% @end
-spec send_data(ConnHandlerPid :: pid(), Data :: binary()) -> ok.
send_data(ConnHandlerPid, Data) ->
    ConnHandlerPid ! {send, Data}, ok.


%% @private
%% @end
init() ->
    receive
        {change_config, {ForwardHop, BackwardHop, From, To}} ->
            loop(#state{forward_hop = ForwardHop, backward_hop = BackwardHop, conn_id = {From, To}});
        {change_config, ForwardHop, From, To} ->
            loop(#state{forward_hop = ForwardHop, conn_id = {From, To}})
    end.

%% @private
%% @end
loop(State) ->
    ForwardHop = State#state.forward_hop,
    BackwardHop = State#state.backward_hop,
    receive
        {send, Data} ->
            io:format("(~p) got send~n", [self()]),
            ForwardHop ! {forward, self(), Data};
        {forward, ForwardHop, Data} when BackwardHop == none -> % Data has arrived
            io:format("(~p) received data ~p~n", [self(), Data]),
            {From, To} = State#state.conn_id,
            FileName = atom_to_list(From) ++ atom_to_list(To) ++ ".data",
            write_to_file(Data, FileName);
        {forward, BackwardHop, Data} ->
            io:format("(~p) forwarding to forward-hop ~p~n", [self(), BackwardHop]),
            ForwardHop ! {forward, self(), Data};
        {forward, ForwardHop, Data} ->
            io:format("(~p) forwarding to backward-hop ~p~n", [self(), BackwardHop]),
            BackwardHop ! {forward, self(), Data}
    end,
    loop(State).


%% @private
%% @end
write_to_file(Data, FileName) ->
    {ok, Handler} = file:open(FileName, [append]),
    file:write(Handler, Data),
    file:close(Handler).
