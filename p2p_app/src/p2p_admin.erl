-module(p2p_admin).

-include_lib("kernel/include/logger.hrl").

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

    start_logger(),

    loop(1),


    stop_logger(),
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

start_logger() ->
    logger:set_module_level(ghs, debug),
    Config = #{
        config => #{
            file => "logs/logs.txt",
            % prevent flushing (delete)
            flush_qlen => 100000,
            % disable drop mode
            drop_mode_qlen => 100000,
            % disable burst detection
            burst_limit_enable => false
        },
        level => debug,
        modes => [write],
        formatter => {logger_formatter, #{template => [pid, " ", msg, "\n"]}}
    },
    logger:add_handler(to_file_handler, logger_std_h, Config),
    logger:set_handler_config(default, level, notice),
    ?LOG_DEBUG("===== LOG START =====").

stop_logger() ->
    ?LOG_DEBUG("===== LOG END ====="),
    logger_std_h:filesync(to_file_handler).
