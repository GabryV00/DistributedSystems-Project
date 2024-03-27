-module(p2p_test).
-include_lib("eunit/include/eunit.hrl").

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).

p2p_test_() ->
    [join_test()].

% start_mst_test() ->
%     {ok, Ref} = p2p_sup:start_link(node1, []),
%     ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
%     unregister(node1).

% start_conn_handler_test() ->
%     {ok, Ref} = p2p_sup:start_link(node1, []),
%     ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
%     unregister(node1).

join_test() ->
    {timeout, 300,
     fun() ->
             p2p_admin_sup:start_link(),
             Nodes = lists:map(fun(N) ->
                                       list_to_atom("node" ++ integer_to_list(N))
                               end,
                               lists:seq(1, 50)),
             lists:foreach(fun(Node) -> p2p_sup:start_link(Node, []) end, Nodes),
             lists:foreach(fun(Node) ->
                                   OtherNodes = lists:delete(Node, Nodes),
                                   p2p_node:join_network(Node, [#edge{src=Node, dst=Dst, weight = trunc(rand:uniform()*100)} || Dst <- OtherNodes])
                           end, Nodes),
             timer:sleep(5000),
             Info = lists:map(fun(Node) -> p2p_node:request_to_communicate(Node, x) end, Nodes),
             ComponentRoots = lists:map(fun([_Node, _State, {component, Root, _Level}]) -> Root end, Info),
             ?debugFmt("~n~p", [lists:map(fun({N,C}) ->
                                                  "node" ++ integer_to_list(N) ++ " " ++ C
                                          end, lists:enumerate(Info))]),
             ?assert(lists:all(fun(R) -> R == hd(ComponentRoots) end, ComponentRoots))
     end}.
