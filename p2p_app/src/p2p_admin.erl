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
        _ ->
            badrequest
    end.
