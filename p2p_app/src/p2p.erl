-module(p2p).

-export([main/1]).
-define(LOG_FILENAME, "logs/log.txt").
-include_lib("kernel/include/logger.hrl").

main(Args) ->
    {ok, #{verbose := Verbose, init := InitDir}, _, _} =
        argparse:parse(Args, #{
            arguments => [
                #{
                    name => verbose,
                    short => $v,
                    long => "verbose",
                    type => boolean,
                    default => false
                },
                #{
                    name => init,
                    short => $i,
                    long => "init",
                    type => string,
                    default => "config_files"
                }

            ]
        }),


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
        level =>
            if
                Verbose -> debug;
                true -> notice
            end,
        modes => [write],
        formatter => {logger_formatter, #{template => [pid, " ", msg, "\n"]}}
    },
    logger:add_handler(to_file_handler, logger_std_h, Config),
    logger:set_handler_config(default, level, notice),

    ?LOG_DEBUG("initdir ~p", [InitDir]),

    start(InitDir),

    logger_std_h:filesync(to_file_handler),
    0.



start() ->
    io:format("Starting Admin~n"),
    p2p_admin_sup:start_link(),
    io:format("Starting Node Manager~n"),
    p2p_node_manager:start_link(),
    loop().

start(InitDir) ->
    ?LOG_DEBUG("Initializing network from ~p", [InitDir]),
    p2p_admin_sup:start_link(),
    p2p_node_manager:start_link(),
    {ok, Files} = file:list_dir(InitDir),
    CompletePaths = [InitDir ++ File || File <- Files],
    lists:foreach(fun p2p_node:init_node_from_file/1, CompletePaths),
    loop().

loop() -> loop().


