-module(p2p_test).
-export([test/0]).

-include_lib("eunit/include/eunit.hrl").

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).

test() ->
    Node1Adjs = [#edge{src = node1, dst = node2, weight = 1}],
    Node2Adjs = [#edge{src = node2, dst = node1, weight = 1}],
    ?assertMatch({ok, Pid}, p2p_sup:start_link(node1, Node1Adjs)),
    ?assertMatch({ok, Pid}, p2p_sup:start_link(node2, Node2Adjs)),
    unregister(node1),
    unregister(node2).

start_mst_test() ->
    {ok, Ref} = p2p_sup:start_link(node1, []),
    ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
    unregister(node1).

start_conn_handler_test() ->
    {ok, Ref} = p2p_sup:start_link(node1, []),
    ?assertMatch({ok, Pid}, p2p_sup:start_mst_worker(Ref)),
    unregister(node1).

join_test() ->
    p2p_admin_sup:start_link(),
    p2p_sup:start_link(node1, []),
    p2p_sup:start_link(node2, []),
    p2p_sup:start_link(node3, []),
    p2p_sup:start_link(node4, []),
    p2p_node:join_network(node1, [#edge{src = node1, dst = node2, weight = 1}]),
    % p2p_node:join_network(node3, [#edge{src = node3, dst = node2, weight = 2},
    %                               #edge{src = node3, dst = node1, weight = 4}]),
    p2p_node:join_network(node4, [#edge{src = node4, dst = node1, weight = 1}]),
    timer:sleep(200).
    % ?debugFmt("~p~n", [p2p_node:get_state(node1)]),
    % ?debugFmt("~p~n", [p2p_node:get_state(node2)]),
    % ?debugFmt("~p~n", [p2p_node:get_state(node3)]),
    % ?debugFmt("~p~n", [p2p_node:get_state(node4)]).


mst_info_test() ->
    join_test(),
    ?debugFmt("~p", [p2p_node:request_to_communicate(node1, undefined)]),
    ?debugFmt("~p", [p2p_node:request_to_communicate(node2, undefined)]).
