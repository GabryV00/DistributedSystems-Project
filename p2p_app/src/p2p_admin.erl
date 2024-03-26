-module(p2p_admin).


-export([init/1, start_link/1]).

-define(EVENTS_FILENAME, "json/events.json").

start_link(Supervisor) ->
    Pid = spawn_link(?MODULE, init, [Supervisor]),
    register(admin, Pid),
    {ok, Pid}.

init(Supervisor) ->
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
