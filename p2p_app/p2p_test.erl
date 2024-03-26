-module(p2p_test).
-export([test/0]).

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).

test() ->
    Node1Adjs = [#edge{src = node1, dst = node2, weight = 1}],
    Node2Adjs = [#edge{src = node2, dst = node1, weight = 1}],
    p2p_sup:start_link(node1, Node1Adjs),
    p2p_sup:start_link(node2, Node2Adjs).
