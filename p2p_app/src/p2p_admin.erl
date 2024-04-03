-module(p2p_admin).

-include_lib("kernel/include/logger.hrl").

-export([init/1, start_link/1, spawn_node/2]).

-define(EVENTS_FILENAME, "json/events.json").

start_link(Supervisor) ->
    Pid = spawn_link(?MODULE, init, [Supervisor]),
    register(admin, Pid),
    {ok, Pid}.

spawn_node(Name, Adjs) ->
    NodeSupSpec = #{id => make_ref(),
                    start => {'p2p_node_sup', start_link, [Name, Adjs]},
                    restart => permanent,
                    shutdown => 5000,
                    type => supervisor,
                    modules => ['p2p_node_sup']},
    supervisor:start_child(p2p_node_manager, NodeSupSpec).

init(Supervisor) ->
    logger:set_module_level(?MODULE, debug),
    asynch_write:init(?EVENTS_FILENAME, "[\n  ", ",\n  ", "\n]"),
    events:init(ghs),
    latency:init(),

    loop(1),


    latency:stop(),
    events:stop(),
    asynch_write:stop().


loop(Counter) ->
    receive
        {From, new_id} ->
            From ! {admin, Counter},
            loop(Counter+1);
        {From, timer} ->
            N = compute_timer_duration(get_peer_count()),
            From ! {admin, N},
            loop(Counter);
        _ ->
            badrequest
    end.

get_peer_count() ->
    proplists:get_value(active, supervisor:count_children(p2p_node_manager)).

%% @doc Computes the timeout value to give to a peer based on network dimesion
%% @param N The number of peers in the network
%% @end
compute_timer_duration(N) ->
    N * 1000.
