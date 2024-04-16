%%%-------------------------------------------------------------------
%%% @author Gianluca Zavan
%%% @doc Application entrypoint.
%%% @end
%%%-------------------------------------------------------------------

-module(p2p).

-export([main/1]).
-define(LOG_FILENAME, "logs/log.txt").
-include_lib("kernel/include/logger.hrl").

%% @doc Application entrypoint.
%% @param Args Various arguments.
%% @end
main(Args) ->
    {ok, #{verbose := Verbose, very_verbose := VeryVerbose, init := InitDir}, _, _} =
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
                    name => very_verbose,
                    short => $V,
                    long => "vv",
                    type => boolean,
                    default => false
                },
                #{
                    name => init,
                    short => $i,
                    long => "init",
                    type => string,
                    default => "../src/init/config_files"
                }

            ]
        }),


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
        case {VeryVerbose, Verbose} of
            {true, _} -> debug;
            {false, true} -> info;
            {false, false} -> error
        end,
        modes => [write],
        % save logs in json format
        formatter => {logger_formatter,
                      #{template => [
                                     "\{",
                                     {process_name, ["\"process_name\":", "\"", process_name, "\","], []},
                                     "\"when\":", "\"", time, "\",",
                                     "\"module\":", "\"", mfa, "\",",
                                     "\"pid\":", "\"", pid, "\","
                                     "\"msg\":", "\"", msg, "\"",
                                     "\}\n"]}}
    },
    logger:add_handler(to_file_handler, logger_std_h, Config),
    logger:set_handler_config(default, level, notice),


    case {VeryVerbose, Verbose} of
        {true, _} ->
            % Set main modules to debug mode
            logger:set_module_level(?MODULE, debug),
            logger:set_module_level(p2p_node, debug),
            logger:set_module_level(ghs, debug);
        {false, true} ->
            logger:set_module_level(?MODULE, info),
            logger:set_module_level(p2p_node, info),
            logger:set_module_level(ghs, info);
        {false, false} ->
            logger:set_module_level(?MODULE, error),
            logger:set_module_level(p2p_node, error),
            logger:set_module_level(ghs, error)
    end,

    ?LOG_DEBUG("initdir ~s", [InitDir]),

    start(InitDir),

    logger_std_h:filesync(to_file_handler),
    0.


%% @doc Starts the main components of the application.
%% The admin supervisor, which starts the TCP endpoint as well, and the node
%% manager, which spawns all the peers and their side processes
%% @end
start() ->
    io:format("Starting Admin~n"),
    p2p_admin_sup:start_link(),
    io:format("Starting Node Manager~n"),
    p2p_node_manager:start_link(),
    loop().

%% @doc Same as start/0, but initializes the network from the config files in InitDir
%% @end
start(InitDir) ->
    ?LOG_DEBUG("Initializing network from ~s", [InitDir]),
    p2p_admin_sup:start_link(),
    p2p_node_manager:start_link(),
    utils:init_network(InitDir),
    io:format("=== NETWORK INIT COMPLETED, NOW LISTENING ===~n"),
    loop().

loop() -> loop().
