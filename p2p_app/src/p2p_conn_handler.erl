-module(p2p_conn_handler).
-export([start_link/0, talk_to/4, talk_to/5, send_data/2]).

-record(state, {
          conn_id :: {term(), term()},
          forward_hop :: pid(),
          backward_hop = none :: pid() | none, % none only for sender or receiver
          parent :: pid()
         }).

start_link() ->
    Pid = spawn_link(fun() -> init() end),
    {ok, Pid}.

init() ->
    receive
        {change_config, {ForwardHop, BackwardHop, From, To}} ->
            loop(#state{forward_hop = ForwardHop, backward_hop = BackwardHop, conn_id = {From, To}});
        {change_config, ForwardHop, From, To} ->
            loop(#state{forward_hop = ForwardHop, conn_id = {From, To}})
    end.

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

talk_to(ConnHandlerPid, ForwardHop, From, To) ->
    ConnHandlerPid ! {change_config, ForwardHop, From, To}.
talk_to(ConnHandlerPid, ForwardHop, BackwardHop, From, To) ->
    ConnHandlerPid ! {change_config, {ForwardHop, BackwardHop, From, To}}.

send_data(ConnHandlerPid, Data) ->
    ConnHandlerPid ! {send, Data}.

write_to_file(Data, FileName) ->
    {ok, Handler} = file:open(FileName, [append]),
    file:write(Handler, Data),
    file:close(Handler).

