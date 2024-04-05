-module(utils).
-export([get_pid_from_id/1, build_edges/2, init_network/1]).

-include("records.hrl").

%% @doc Transforms numeric ID into atom that represents the peer node
%% @end
get_pid_from_id(Id) when is_integer(Id) ->
    list_to_atom("node" ++ integer_to_list(Id));
get_pid_from_id(Id) when is_list(Id) ->
    list_to_atom("node" ++ Id);
get_pid_from_id(Id) when is_bitstring(Id) ->
    list_to_atom("node" ++ bitstring_to_list(Id)).

%% @doc Transforms the edges from JSON into internal format
%% @param Src Is the node from which the edge goes out
%% @param Edges Are the outgoing edges in form [Dst, Weight]
%% @end
build_edges(Src, Edges) when is_list(Edges)->
    lists:map(fun([Dst, Weight]) ->
                #edge{src = Src,
                      dst = get_pid_from_id(Dst),
                      weight = Weight}
              end, Edges).

%% @doc Initializes the network from the JSON config files in InitDir
%% @end
init_network(InitDir) ->
    {ok, Files} = file:list_dir(InitDir),
    CompletePaths = [InitDir ++ File || File <- Files],
    NodesWithEdges = lists:map(fun p2p_node:init_node_from_file/1, CompletePaths),
    lists:foreach(fun({Node, Edges}) -> p2p_node:join_network(Node, Edges) end, NodesWithEdges),
    _Nodes = [Node || {Node, _Edge} <- NodesWithEdges].
