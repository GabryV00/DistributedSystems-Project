-module(p2p_test).
-include_lib("eunit/include/eunit.hrl").

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

p2p_test_() ->
    {"Main test generator",
     {foreach,
      fun setup/0,
      fun cleanup/1,
      [
       fun kill_node_while_computing_mst/1,
       % fun request_to_communicate_no_mst/1,
       % fun request_to_communicate/1,
       % fun request_to_communicate_no_band/1,
       % fun request_to_communicate_intermediate_dead/1
       % fun send_data/1,
       % fun send_data_to_dead_node/1,
       ?_assert(true)
      ]}}.

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

    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),
    _Nodes = utils:init_network("./config_files/").

cleanup(Nodes) ->
    % AdminSup = whereis(p2p_admin_sup),
    % NodeManager = whereis(p2p_node_manager),
    % unlink(AdminSup),
    % unlink(NodeManager),
    % unregister(p2p_node_manager),
    % unregister(p2p_admin_sup),
    % exit(AdminSup, shutdown),
    % exit(NodeManager, shutdown)
    lists:foreach(fun(Node) -> 
                          case whereis(Node) of
                              undefined -> ok;
                              _Name -> unregister(Node)
                          end
                  end, Nodes),
    ok.

% start_mst_test() ->
%     {ok, Ref} = p2p_sup:start_link(node1, []),
%     ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
%     unregister(node1).

% start_conn_handler_test() ->
%     {ok, Ref} = p2p_sup:start_link(node1, []),
%     ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
%     unregister(node1).

% join_test() ->
%     {timeout, 300,
%      fun() ->
%              p2p_admin_sup:start_link(),
%              Nodes = lists:map(fun(N) ->
%                                        list_to_atom("node" ++ integer_to_list(N))
%                                end,
%                                lists:seq(1, 50)),
%              lists:foreach(fun(Node) -> p2p_node_sup:start_link(Node, []) end, Nodes),
%              lists:foreach(fun(Node) ->
%                                    OtherNodes = lists:delete(Node, Nodes),
%                                    p2p_node:join_network(Node, [#edge{src=Node, dst=Dst, weight = trunc(rand:uniform()*100)} || Dst <- OtherNodes])
%                            end, Nodes),
%              timer:sleep(5000),
%              Info = lists:map(fun(Node) -> p2p_node:request_to_communicate(Node, x) end, Nodes),
%              ComponentRoots = lists:map(fun([_Node, _State, {component, Root, _Level}]) -> Root end, Info),
%              ?debugFmt("~n~p", [lists:map(fun({N,C}) ->
%                                                   "node" ++ integer_to_list(N) ++ " " ++ C
%                                           end, lists:enumerate(Info))]),
%              ?assert(lists:all(fun(R) -> R == hd(ComponentRoots) end, ComponentRoots))
%      end}.

init_node_from_file_test() ->
    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),
    p2p_node:init_node_from_file("../src/init/config_files/node_1.json"),
    ?_assertNotException(exit, {noproc, _}, p2p_node:get_state(node1)).

init_test() ->
    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),
    utils:init_network("../src/init/config_files/"),
    ?_assertNotException(exit, {noproc, _}, p2p_node:get_state(node1)).


join_after_init_test() ->
    p2p_node_manager:start_link(),
    p2p_admin_sup:start_link(),
    Nodes = utils:init_network("../src/init/config_files/"),
    p2p_node:join_network(node100, [{edge,node1,node100,1}, {edge,node9,node100,90}]),
    ?_assert(is_list(Nodes)).

start_mst_test() ->
    {timeout, 300,
     fun() ->
        p2p_node_manager:start_link(),
        p2p_admin_sup:start_link(),
        Nodes = utils:init_network("./config_files/"),
        p2p_node:start_mst_computation(node1),
        p2p_node:start_mst_computation(node3),
        p2p_node:start_mst_computation(node10),
        timer:sleep(5000),
        States = lists:map(fun p2p_node:get_state/1, Nodes),
        Info = [FinishedMst || {state, _Name, _Adjs, _MstAdjs, _Sup, _ConnSup, _SessionID, _Connections, _MstComputer, FinishedMst} <- States],
        ?assert(lists:all(fun(X) -> X == true end, Info))
     end}.

get_mst_worker_test() ->
    {ok, Sup} = p2p_node_sup:start_link(node1, []),
    {ok, Pid} = p2p_node_sup:start_mst_worker(Sup, node1),
    ?_assert(is_pid(Pid)).


kill_node_while_computing_mst(Nodes) ->
    {timeout, 300,
     fun() ->
             p2p_node:start_mst_computation(node1),
             p2p_node:leave_network(node1),
             p2p_node:leave_network(node3),
             timer:sleep(100000),
             States = lists:map(fun p2p_node:get_state/1, lists:subtract(Nodes, [node1, node3])),
             Info = [FinishedMst || #state{mst_state = FinishedMst} <- States],
             Sessions = [SessionID || #state{current_mst_session = SessionID} <- States],
             ?assert(lists:all(fun(X) -> X == computed end, Info)),
             ?assert(lists:all(fun(X) -> X == hd(Sessions) end, Sessions))
     end}.


request_to_communicate_no_mst(_Nodes) ->
    Reply = p2p_node:request_to_communicate(node1, node2, 1),
    ?_assertMatch({no_mst, _Name}, Reply).

request_to_communicate(_Nodes) ->
    p2p_node:join_network(node21, [{edge, node1, node21, 10}]),
    p2p_node:start_mst_computation(node21),
    timer:sleep(30000),
    Reply = p2p_node:request_to_communicate(node21, node2, 1),
    ?_assertMatch({ok, _Pid}, Reply).

request_to_communicate_no_band(_Nodes) ->
    p2p_node:start_mst_computation(node1),
    timer:sleep(5000),
    Reply = p2p_node:request_to_communicate(node1, node2, 100000),
    ?_assertMatch({no_band, {_Hop, _Weight}}, Reply).


request_to_communicate_intermediate_dead(_Nodes) ->
    p2p_node:join_network(node21, [{edge, node1, node21, 10}]),
    p2p_node:start_mst_computation(node21),
    timer:sleep(30000),
    p2p_node:leave_network(node1),
    Reply = p2p_node:request_to_communicate(node21, node2, 1),
    ?_assertMatch({noproc, _Node}, Reply).

send_data(_) ->
    p2p_node:start_mst_computation(node1),
    timer:sleep(10000),
    p2p_node:request_to_communicate(node1, node2, 1),
    ToSend = <<"Hello World">>,
    p2p_node:send_data(node1, node2, ToSend),
    timer:sleep(1000),
    {ok, Read} = file:read_file("node1node2.data"),
    file:delete("node1node2.data"),
    ?_assertEqual(ToSend, Read).


send_data_to_dead_node(_) ->
    p2p_node:start_mst_computation(node9),
    timer:sleep(10000),
    p2p_node:request_to_communicate(node2, node10, 1),
    p2p_node:leave_network(node10),
    p2p_node:send_data(node2, node10, <<"Hello">>).
