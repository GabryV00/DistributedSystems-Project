-module(p2p_admin).

-export([start_link/1, spawn_node/2]).

-include("records.hrl").
-define(EVENTS_FILENAME, "json/events.json").

%% @doc Spawns the admin process
%% @param Supervisor The pid of the admin supervisor
%% @end
-spec start_link(Supervisor :: pid()) -> {ok, pid()} | {error, Reason :: term()}.
start_link(Supervisor) ->
    Pid = spawn_link(fun() -> init(Supervisor) end),
    register(admin, Pid),
    {ok, Pid}.

%% @doc Asks the node manager to spawn a new node with the given name and neighbors
%% @param Name The name of the new node
%% @param Adjs The list of incident edges of the node
%% @end
-spec spawn_node(Name :: pid(), Adjs :: [#edge{}]) -> {ok, Child :: pid()} | {error, Reason :: term()}.
spawn_node(Name, Adjs) ->
    NodeSupSpec = #{id => make_ref(),
                    start => {'p2p_node_sup', start_link, [Name, Adjs]},
                    restart => permanent,
                    shutdown => 5000,
                    type => supervisor,
                    modules => ['p2p_node_sup']},
    supervisor:start_child(p2p_node_manager, NodeSupSpec).

%% @private
%% @doc Admin node initialization
%% @end
init(Supervisor) ->
    logger:set_module_level(?MODULE, debug),
    asynch_write:init(?EVENTS_FILENAME, "[\n  ", ",\n  ", "\n]"),
    events:init(ghs),
    latency:init(),

    loop(1),


    latency:stop(),
    events:stop(),
    asynch_write:stop().


%% @private
%% @doc Main admin logic, gives fresh MST sessions and timer based on # of peers in the network
%% @end
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

%% @private
%% @doc Computes the total number of peers in the network
%% @end
get_peer_count() ->
    proplists:get_value(active, supervisor:count_children(p2p_node_manager)).

%% @doc Computes the timeout value to give to a peer based on network dimesion
%% @param N The number of peers in the network
%% @end
compute_timer_duration(N) ->
    N * 1000.
