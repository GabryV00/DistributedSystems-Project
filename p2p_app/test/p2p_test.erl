%%% --------------------------------------------------------------------------- 
%%% @author Gianluca Zavan
%%% @doc Unit tests.
%%% @end
%%% --------------------------------------------------------------------------- 
-module(p2p_test).
-include_lib("eunit/include/eunit.hrl").
-export([init_network/0]).

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).
-record(state, {
          name :: term(),
          adjs = [] :: [#edge{}],
          mst_adjs = [] :: [#edge{}],
          supervisor :: pid(),
          current_mst_session :: term(),
          connections = [] :: list(),
          mst_computer_pid :: pid(),
          mst_state = undefined :: computed | computing | undefined,
          mst_routing_table = #{} :: #{term() => #edge{}},
          mst_parent = none :: #edge{} | none,
          conn_handlers = #{} :: #{{term(), term()} => pid()}
         }).

-define(INITDIR, "../src/init/config_files/").
-define(BACKUPDIR, "../src/init/config_files_bak/").

%%% ---------------------------------------------------------------------------
%%% TEST GENERATORS
%%% ---------------------------------------------------------------------------

p2p_test_() ->
    {"Main test generator",
     {foreach,
      fun setup/0,
      fun cleanup/1,
      [
       fun join_after_init/1,
       fun remove_peer/1,
       fun start_mst/1,
       fun join_during_mst/1,
       fun kill_node_while_computing_mst/1,
       fun request_to_communicate_no_mst/1,
       fun request_to_communicate/1,
       fun request_to_communicate_no_band/1,
       fun request_to_communicate_intermediate_dead/1,
       fun send_data/1,
       fun send_data_to_dead_peer/1,
       fun close_connection/1
      ]}}.


%%% ---------------------------------------------------------------------------
%%% SETUP AND CLEANUP
%%% ---------------------------------------------------------------------------

setup() ->
    Config = #{
               config => #{
                           file => "logs/log.txt",
                           % prevent flushing (delete)
                           flush_qlen => 100000,
                           % disable drop mode
                           drop_mode_qlen => 100000,
                           % disable burst detection
                           burst_limit_enable => false,
                           filesync_repeat_interval => 500
                          },
               level => debug,
               modes => [write],
               formatter => {logger_formatter, #{template => [pid, " ", msg, "\n"]}}
              },
    logger:add_handler(to_file_handler, logger_std_h, Config),

    logger:set_module_level(p2p_node, debug),
    logger:set_module_level(ghs, debug),

    % Start the core modules
    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),

    % Backup the config files to be later restored
    file:make_dir(?BACKUPDIR),
    copy_directory(?INITDIR, ?BACKUPDIR),

    % Initialize the network
    _Nodes = utils:init_network(?INITDIR).

cleanup(Nodes) ->
    % Delete all the registered names
    lists:foreach(fun(Node) ->
                          case whereis(Node) of
                              undefined -> ok;
                              _Name -> unregister(Node)
                          end
                  end, Nodes),

    % Kill the node manager and the admin supervisor, bringing down the network
    unlink(whereis(p2p_node_manager)),
    unlink(whereis(p2p_admin_sup)),
    exit(whereis(p2p_node_manager), normal),
    exit(whereis(p2p_admin_sup), normal),
    % Wait for a moment for all processes in the tree to terminate
    timer:sleep(500),

    % Restore back the config files from the backup dir
    file:del_dir_r(?INITDIR),
    file:make_dir(?INITDIR),
    copy_directory(?BACKUPDIR, ?INITDIR),
    % Delete the backup files
    file:del_dir_r(?BACKUPDIR),
    ok.


%%% ---------------------------------------------------------------------------
%%% TESTS
%%% ---------------------------------------------------------------------------


init_node_from_file(_) ->
    p2p_node:init_node_from_file("../src/init/config_files/node_1.json"),
    ?_assertNotException(exit, {noproc, _}, p2p_node:get_state(node1)).

init_network() ->
    % Start the main components
    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),
    % Initialize the network
    Nodes = utils:init_network("../src/init/config_files/"),
    Outcomes = lists:map(fun(T) ->
                                 try
                                     % The call is succesful only if the peer started
                                     p2p_node:get_state(T),
                                     true
                                 catch
                                     error:_ -> false
                                 end
                         end, Nodes),
    % Every peer should must be up
    ?assert(lists:all(fun(X) -> X == true end, Outcomes)).


join_after_init(Nodes) ->
    % Network already initiated
    % A new peer joins the network
    p2p_node:join_network(node500, [{edge,node1,node500,1}]),
    % Then it starts the computation of a new MST
    p2p_node:start_mst_computation(node500),
    timer:sleep(5000),
    AllNodes = [node500 | Nodes],
    % Check that the MST has been computed
    check_mst(AllNodes).


join_during_mst(Nodes) ->
    % A new peer joins the network
    p2p_node:join_network(node500, [{edge, node1, node500, 10}]),
    % Another peer starts the computation before the new one
    p2p_node:start_mst_computation(node1),
    % The new one starts the computation aswell
    p2p_node:start_mst_computation(node500),
    timer:sleep(5000),
    AllNodes = [node500 | Nodes],
    check_mst(AllNodes).


% Assuming a connected graph
start_mst(Nodes) ->
    {timeout, 30,
     fun() ->
        % Make one of the nodes start the computation of the MST
        p2p_node:start_mst_computation(hd(Nodes)),
        % Wait for all the messages to propagate
        timer:sleep(10000),
        check_mst(Nodes)
     end}.

get_mst_worker() ->
    {ok, Sup} = p2p_node_sup:start_link(node1, []),
    {ok, Pid} = p2p_node_sup:start_mst_worker(Sup, node1),
    ?_assert(is_pid(Pid)).


request_to_communicate(_Nodes) ->
    % Add a new node
    p2p_node:join_network(node21, [{edge, node1, node21, 10}]),
    % Make it start the computation of the MST
    p2p_node:start_mst_computation(node21),
    timer:sleep(5000),
    Reply = p2p_node:request_to_communicate(node21, node2, 1),
    % The request should be succesful
    ?_assertMatch({ok, _Pid}, Reply).



request_to_communicate_no_mst(_Nodes) ->
    Reply = p2p_node:request_to_communicate(node1, node2, 1),
    % The request should fail with {no_mst, _} return value
    ?_assertMatch({no_mst, _Name}, Reply).


request_to_communicate_no_band(_Nodes) ->
    p2p_node:start_mst_computation(node1),
    timer:sleep(5000),
    % Ask for an enormous amount of band
    Reply = p2p_node:request_to_communicate(node1, node2, 100000),
    % The request should fail with a {no_band, _} return value
    ?_assertMatch({no_band, {_Hop, _Weight}}, Reply).


request_to_communicate_intermediate_dead(_Nodes) ->
    % Add a new peer and connect it to node1
    p2p_node:join_network(node21, [{edge, node1, node21, 10}]),
    p2p_node:start_mst_computation(node21),
    timer:sleep(5000),
    % Make node1 leave the network
    p2p_node:leave_network(node1),
    Reply = p2p_node:request_to_communicate(node21, node2, 1),
    % The request should fail with a {noproc, _} return value
    ?_assertMatch({noproc, _Node}, Reply).

send_data(_) ->
    p2p_node:start_mst_computation(node1),
    timer:sleep(5000),
    % Establish a connection
    p2p_node:request_to_communicate(node1, node2, 1),
    ToSend = <<"Hello World">>,
    % Send some data
    p2p_node:send_data(node1, node2, ToSend),
    timer:sleep(1000),
    % Verify that the data has been actually written on a file
    {ok, Read} = file:read_file("node1node2.data"),
    file:delete("node1node2.data"),
    ?_assertEqual(ToSend, Read).


send_data_to_dead_peer(_) ->
    p2p_node:start_mst_computation(node9),
    timer:sleep(5000),
    % Establish a connection
    p2p_node:request_to_communicate(node2, node10, 1),
    % The other node leaves the network
    p2p_node:leave_network(node10),
    % Try to send some data
    Reply = p2p_node:send_data(node2, node10, <<"Hello">>),
    % An ACK is not expected, sending data shouldn't fail
    ?_assertMatch(ok, Reply).

close_connection(_) ->
    p2p_node:start_mst_computation(node1),
    timer:sleep(5000),
    p2p_node:request_to_communicate(node1, node4, 1),
    % Close connection starting from node4
    p2p_node:close_connection(node4, node1),
    timer:sleep(100),
    % Try to send data from node1
    Reply = p2p_node:send_data(node1, node4, <<"">>),
    % The connection must have been closed from both sides
    ?_assertMatch({no_connection, {node1, node4}}, Reply).


kill_node_while_computing_mst(Nodes) ->
    {timeout, 300,
     fun() ->
             p2p_node:start_mst_computation(node1),
             % Make node1 leave the network as soon as possible
             p2p_node:leave_network(node1),
             % wait for timeouts to trigger
             timer:sleep(100000),
             % Get the state of all the remaining nodes
             States = lists:map(fun p2p_node:get_state/1, lists:subtract(Nodes, [node1])),
             Info = [FinishedMst || #state{mst_state = FinishedMst} <- States],
             Sessions = [SessionID || #state{current_mst_session = SessionID} <- States],
             % Check that everyone finished computing the MST and in in the same session
             ?assert(lists:all(fun(X) -> X == computed end, Info)),
             ?assert(lists:all(fun(X) -> X == hd(Sessions) end, Sessions))
     end}.

check_mst(Nodes) ->
    States = lists:map(fun p2p_node:get_state/1, Nodes),
    Info = [FinishedMst || #state{mst_state = FinishedMst} <- States],
    Sessions = [SessionID || #state{current_mst_session = SessionID} <- States],
    % Check if all the peers have finished computing the MST
    ?_assert(lists:all(fun(X) -> X == computed end, Info)),
    % Check that all the MST sessions are the equal (no one left behind)
    ?_assert(lists:all(fun(X) -> X == hd(Sessions) end, Sessions)).


remove_peer(Nodes) ->
    ToRemove = hd(Nodes),
    p2p_node:leave_network(ToRemove),
    % The process should not exist anymore
    ?_assertEqual(undefined, whereis(ToRemove)).


%%% ---------------------------------------------------------------------------
%%% UTILITY FUNCTIONS
%%% ---------------------------------------------------------------------------

copy_directory(SourceDir, DestDir) ->
    {ok, Files} = file:list_dir(SourceDir),
    lists:foreach(fun(File) ->
                          SourceFile = filename:join([SourceDir, File]),
                          DestFile = filename:join([DestDir, File]),
                          case filelib:is_regular(SourceFile) of
                              true ->
                                  {ok, _BytesCopied} = file:copy(SourceFile, DestFile);
                              false ->
                                  file:make_dir(DestFile),
                                  copy_directory(SourceFile, DestFile)
                          end
                  end, Files).
