-module(p2p_test).
-include_lib("eunit/include/eunit.hrl").

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).

p2p_test_() ->
    [start_mst_test()].

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
        timer:sleep(5000),
        States = lists:map(fun p2p_node:get_state/1, Nodes),
        Info = [FinishedMst || {state, _Name, _Adjs, _MstAdjs, _Sup, _ConnSup, _SessionID, _Connections, _MstComputer, FinishedMst} <- States],
        ?assert(lists:all(fun(X) -> X == true end, Info))
     end}.

get_mst_worker_test() ->
    {ok, Sup} = p2p_node_sup:start_link(node1, []),
    {ok, Pid} = p2p_node_sup:start_mst_worker(Sup, node1),
    ?_assert(is_pid(Pid)).
