-module(ghs).

-behaviour(events).
-export([on_process_state/5, on_link_state/6, on_message/9]).

-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/logger.hrl").

%% API
-export([main/1, start/0, start_link/0]).

%% MACROS
-define(LOG_FILENAME, "logs/log.txt").
-define(GRAPH_FILENAME, "json/graph.json").
-define(EVENTS_FILENAME, "json/events.json").
-define(LATENCY, 10).
-define(Expected_replies(Node), length(Node#node.children) + erlang:min(length(Node#node.undecided), 1)).


% STRUCTS
-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).
-record(node, {
    id :: pid(),
    parent = none :: #edge{} | none,
    children = [] :: [#edge{}],
    rejected = [] :: [#edge{}],
    undecided = [] :: [#edge{}],
    minimax_routing_table = #{} :: #{pid() => #edge{}}
}).
-record(component, {core :: pid(), level = 0 :: non_neg_integer()}).
-record(candidate, {source_id :: pid(), edge :: #edge{}}).
-record(state, {
    phase :: searching | found,
    replies = 0 :: non_neg_integer(),
    candidate = none :: #candidate{} | none,
    selected = false :: boolean(),
    supervisor :: pid(),
    representative = none :: nonempty_string() | none,
    sum = 0 :: non_neg_integer(),
    mst_session :: non_neg_integer()
}).


start_link() ->
    Pid = spawn_link(fun() -> node_start(self()) end),
    {ok, Pid}.

do_nothing() ->
    do_nothing().



%% escript entry point
main(Args) ->
    {ok, #{verbose := Verbose}, _, _} =
        argparse:parse(Args, #{
            arguments => [
                #{
                    name => verbose,
                    short => $v,
                    long => "verbose",
                    type => boolean,
                    default => false
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

    start(),

    logger_std_h:filesync(to_file_handler),
    0.


%% algorithm entry point (can be executed from shell)  
start() ->
    asynch_write:init(?EVENTS_FILENAME, "[\n  ", ",\n  ", "\n]"),
    events:init(?MODULE),
    latency:init(),

    Supervisor = self(),

    % load graph, spawn a process for each node, and stores node-pid bijections
    Graph = datagraph:load(?GRAPH_FILENAME),
    Nodes = datagraph:get_list_of_nodes(Graph),
    NodeToPid = lists:foldl(fun (V, Acc) -> 
                                Pid = spawn(fun () -> node_start(Supervisor) end),
                                maps:put(V, Pid, Acc)
                            end,
                            maps:new(), Nodes),
    PidToNode = lists:foldl(fun (V, Acc) -> 
                                Pid = maps:get(V, NodeToPid),
                                maps:put(Pid, V, Acc)
                            end,
                            maps:new(), Nodes),

    % log the possible locations of events (locations are now process ids, converted from node ids)
    % locations are annotated with positions and weights
    lists:foreach(fun ({V, [X, Y]}) -> 
                      save_node(maps:get(V, NodeToPid), X, Y)
                  end, 
                  datagraph:get_list_of_datanodes(Graph)),
    lists:foreach(fun ({V1, V2, Weight}) -> 
                      save_link(maps:get(V1, NodeToPid), maps:get(V2, NodeToPid), Weight) 
                  end, 
                  datagraph:get_list_of_dataedges(Graph)),

    % inform node processes about their neighbours, which then start executing the algorithm
    lists:foreach(fun (V1) ->
                      Pid = maps:get(V1, NodeToPid),
                      Adjs = lists:map(fun ({V2, Weight}) -> 
                                           #edge{src = Pid, dst = maps:get(V2, NodeToPid), weight = Weight}
                                       end, 
                                       datagraph:get_list_of_dataadjs(V1, Graph)),
                      Pid ! {change_adjs, Adjs}
                  end,
                  Nodes),

    % supervise node processes
    supervise(length(maps:keys(PidToNode))),
    % timer:sleep(1000),

    latency:stop(),
    events:stop(),
    asynch_write:stop()



    .



%% RESERVED


supervise(N) ->
    supervise(N, []).

supervise(N, Components) when N > 0 ->
    ?LOG_DEBUG("N = ~p", [N]),
    receive
        {component, C} ->
            supervise(N, [C | Components]);
        {done} ->
            supervise(N - 1, Components)
    end;

supervise(0, Components) ->
    String = lists:foldl(
        fun({Representative, Sum}, Acc) ->
            case Acc of
                "" -> Sep = "";
                _ -> Sep = ", "
            end,
            lists:flatten([
                Acc,
                io_lib:format("~s[\"~s\", ~w]", [Sep, Representative, Sum])
            ])
        end,
        "",
        Components
    ),
    % datagraph:fwrite_partial_graph(standard_io, Graph)
    % TO BE DONE: EXPORT SPANNING TREE
    io:fwrite(standard_io, "\"components\": [~s]}", [String]).


root_action(Node, #state{representative = none} = State, Component) ->
    broadcast(Node, State, Component);

root_action(Node, State, _Component) ->
    ?LOG_DEBUG("~p", [Node#node.minimax_routing_table]),
    State#state.supervisor ! {component, {State#state.representative, State#state.sum}}.


done_action(Supervisor) ->
    ?LOG_DEBUG("done to ~w", [Supervisor]),
    Supervisor ! {done}.


node_start(Supervisor) ->
    receive
        {change_adjs, Adjs} -> 
            SortedAdjs = lists:sort(fun compare_edge/2, Adjs)
    end,
    % events:process_state({core, 0}),
    search(
        #node{id = self(), undecided = SortedAdjs},
        #state{supervisor = Supervisor, phase = searching},
        #component{level = 0, core = self()}
    ).


% THE CHAIN OF CALLS COULD BE SIMPLIFIED
node_loop(Node, State, Component) ->
    % update visualization (core node, parent link, selected children, rejected edges)
    Core = Component#component.core,
    case self() of
        Core -> events:process_state({core, Component#component.level});
        _ -> events:process_state({normal, 0})
    end,
    ParentLink = Node#node.parent,
    case ParentLink of
        none -> ok;
        _ -> 
            % events:link_state(ParentLink#edge.dst, ParentLink#edge.src, deleted), % maybe remove this
            events:link_state(ParentLink#edge.src, ParentLink#edge.dst, accepted)
    end,
    lists:foreach(fun (Link) ->
                      case Link of
                          ParentLink -> ok;
                          _ ->                
                              events:link_state(Link#edge.src, Link#edge.dst, deleted)
                      end
                  end,
                  Node#node.children),
    lists:foreach(fun (Link) ->
                      case Link of
                          ParentLink -> ok;
                          _ ->                
                              events:link_state(Link#edge.src, Link#edge.dst, rejected)
                      end
                  end,
                  Node#node.rejected),
    events:tick(),

    % message consumption
    receive
        {SessionID, _} = Msg when SessionID > State#state.mst_session ->
            self() ! Msg, % re-send the message to be consumed later
            SortedAdjs = lists:sort(fun compare_edge/2, Node#node.undecided ++ Node#node.rejected),
            search(
              #node{id = self(), undecided = SortedAdjs},
              #state{phase = searching, mst_session = SessionID},
              #component{level = 0, core = self()}
             );
        {From, get_state} ->
            From ! {self(), [Node, State, Component]},
            node_loop(Node, State, Component);
        {change_adjs, Adjs} ->
            events:tick(),
            SortedAdjs = lists:sort(fun compare_edge/2, Adjs),
            search(
                #node{id = self(), undecided = SortedAdjs},
                #state{phase = searching},
                #component{level = 0, core = self()}
            );
        {{test, Source_Id, Source_Component}, _} = Msg when Component#component.level >= Source_Component#component.level ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("test from ~w, ~w", [Source_Id, Source_Component]),
            test(Node, State, Component, Source_Id, Source_Component);
        {accept, _} = Msg ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got accept", []),
            ?assertEqual(
                searching,
                State#state.phase,
                io_lib:format("accept received in ~p phase", [State#state.phase])
            ),
            Candidate = #candidate{source_id = Node#node.id, edge = hd(Node#node.undecided)},
            report(
                Node,
                State#state{
                    replies = State#state.replies + 1,
                    candidate =
                        min(fun compare_candidate/2, State#state.candidate, Candidate)
                },
                Component
            );
        {reject, _} = Msg ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got reject", []),
            ?assertEqual(
                searching,
                State#state.phase,
                lists:flatten(
                    io_lib:format("reject received in ~p phase", [State#state.phase])
                )
            ),
            ?assert(length(Node#node.undecided) > 0, io_lib:format("reject without undecided", [])),
            
            search(
                Node#node{
                    undecided = tl(Node#node.undecided),
                    rejected = [hd(Node#node.undecided) | Node#node.rejected]
                },
                State,
                Component
            );
        {{report, Candidate}, _} = Msg ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got report, ~w", [Candidate]),
            ?assertEqual(
                searching,
                State#state.phase,
                io_lib:format("report received in ~p phase", [State#state.phase])
            ),
            report(
                Node,
                State#state{
                    replies = State#state.replies + 1,
                    candidate =
                        min(fun compare_candidate/2, State#state.candidate, Candidate)
                },
                Component
            );
        {notify, _} = Msg ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got notify", []),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("notify received in ~p phase", [State#state.phase])
            ),
            notify(Node, State, Component);
        {{merge, Source_Id, Source_Level}, _} = Msg when Component#component.level > Source_Level ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("merge (quick) from ~w, ~w", [Source_Id, Source_Level]),
            merge(Node, State, Component, Source_Id, Source_Level);
        {{merge, Source_Id, Source_Level}, _} = Msg when Component#component.level == Source_Level andalso
                                                         State#state.selected andalso
                                                         State#state.candidate#candidate.edge#edge.dst == Source_Id ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("merge from ~w, ~w", [Source_Id, Source_Level]),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("merge (slow) received in ~p phase", [State#state.phase])
            ),
            merge(Node, State, Component, Source_Id, Source_Level);
        {{update, New_Component, Phase}, _} = Msg ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got update, ~w ~w", [New_Component, Phase]),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("update received in ~p phase", [State#state.phase])
            ),
            update(Node, State#state{phase = Phase}, New_Component);
        {broadcast, _} = Msg ->
            events:received_annotated_msg(Msg),
            broadcast(Node, State, Component);
        {{convergecast, Source_Representative, Source_Sum, Minimax_Routing_Table}, _} = Msg ->
            events:received_annotated_msg(Msg),
            convergecast(
                Node#node{
                    minimax_routing_table = maps:merge(
                        Node#node.minimax_routing_table, Minimax_Routing_Table
                    )
                },
                State#state{
                    replies = State#state.replies + 1,
                    representative = max(State#state.representative, Source_Representative),
                    sum = State#state.sum + Source_Sum
                },
                Component
            );
        {{route, Dst, Dist}, _} = Msg when Dst == Node#node.id ->
            events:received_annotated_msg(Msg),
            ?LOG_DEBUG("got long distance ~p", [Dist]),
            node_loop(Node, State, Component);
        {{route, Dst, _}, _} = Msg ->
            events:received_annotated_msg(Msg),
            Next_Hop_Edge = maps:get(Dst, Node#node.minimax_routing_table, Node#node.parent),
            events:tick(),
            send(Next_Hop_Edge#edge.dst, Msg),
            node_loop(Node, State, Component)
    end.


test(Node, State, Component, Source_Id, #component{core = Source_Core}) ->
    case Component#component.core of
        Source_Core ->
            ?LOG_DEBUG("reject to ~w", [Source_Id]),
            events:tick(),
            send(Source_Id, reject);
        _ ->
            ?LOG_DEBUG("accept to ~w", [Source_Id]),
            events:tick(),
            send(Source_Id, accept)
    end,
    node_loop(Node, State, Component).


search(#node{undecided = [Edge | _]} = Node, State, Component) ->
    ?LOG_DEBUG("test to ~w, ~w", [Edge#edge.dst, Component]),
    events:tick(),
    send(Edge#edge.dst, {test, Node#node.id, Component}),
    node_loop(Node, State, Component);

search(Node, #state{replies = Replies} = State, Component) when Replies == ?Expected_replies(Node) ->
    report(Node, State, Component);

search(Node, State, Component) ->
    node_loop(Node, State, Component).


report(#node{parent = none} = Node, #state{candidate = none} = State, Component) when State#state.replies == ?Expected_replies(Node) ->
    root_action(Node, State, Component);

report(#node{parent = none} = Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    notify(Node, State#state{phase = found}, Component);

report(Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    Reported_Candidate =
        case State#state.candidate of
            none ->
                none;
            Candidate ->
                Candidate#candidate{source_id = Node#node.id}
        end,
    ?LOG_DEBUG(
        "report to ~w, ~w",
        [Node#node.parent#edge.dst, Reported_Candidate]
    ),
    events:tick(),
    send(Node#node.parent#edge.dst, {report, Reported_Candidate}),
    node_loop(Node, State#state{phase = found}, Component);

report(Node, State, Component) ->
    node_loop(Node, State, Component).


notify(Node, #state{candidate = Candidate} = State, Component) when Candidate#candidate.source_id == Node#node.id ->
    ?LOG_DEBUG(
        "merge to ~w, ~w",
        [Candidate#candidate.edge#edge.dst, Component#component.level]
    ),
    events:tick(),
    send(Candidate#candidate.edge#edge.dst, {merge, Node#node.id, Component#component.level}),
    node_loop(Node#node{undecided = tl(Node#node.undecided)}, State#state{selected = true}, Component);   % modified to avoid testing again the core edge

notify(Node, #state{candidate = Candidate} = State, Component) ->
    {[Source_Edge], Children} =
        lists:partition(
            fun(Edge) -> Edge#edge.dst == Candidate#candidate.source_id end,
            Node#node.children
        ),
    ?LOG_DEBUG("notify to ~w", [Source_Edge#edge.dst]),
    events:tick(),
    send(Source_Edge#edge.dst, notify),
    node_loop(
        Node#node{
            parent = Source_Edge,
            children = list(Node#node.parent) ++ Children
        },
        State,
        Component
    ).


merge(Node, State, Component, Source_Id, Source_Level) when Component#component.level > Source_Level ->
    % Source_Edge is not a candidate when Component.level > Source_Level
    {value, Source_Edge} =
        lists:search(fun(Edge) -> Edge#edge.dst == Source_Id end, Node#node.undecided),
    ?LOG_DEBUG("update to ~w, ~w ~w", [Source_Id, State#state.phase, Component]),
    events:tick(),
    send(Source_Id, {update, Component, State#state.phase}),
    node_loop(
        Node#node{children = [Source_Edge | Node#node.children]},
        State,
        Component
    );

merge(Node, State, Component, Source_Id, _Source_Level) ->
    New_Component =
        Component#component{
            core = max(Node#node.id, Source_Id),
            level = Component#component.level + 1
        },
    ?LOG_DEBUG("update to ~w, ~w ~w", [Source_Id, searching, New_Component]),
    events:tick(),
    send(Source_Id, {update, New_Component, searching}),
    node_loop(Node, State, Component).


update(Node, #state{selected = false} = State, Component) ->
    lists:map(
        fun(#edge{dst = Edge_Dst}) ->
            ?LOG_DEBUG(
                "update to ~w, ~w ~w",
                [Edge_Dst, State#state.phase, Component]
            ),
            events:tick(),
            send(Edge_Dst, {update, Component, State#state.phase})
        end,
        Node#node.children
    ),
    New_State =
        State#state{
            replies = 0,
            candidate = none,
            selected = false
        },
    case New_State#state.phase of
        searching ->
            search(Node, New_State, Component);
        _ ->
            node_loop(Node, New_State, Component)
    end;

update(Node, #state{candidate = Candidate} = State, Component) ->
    New_Children = list(Node#node.parent) ++ Node#node.children,
    lists:map(
        fun(#edge{dst = Edge_Dst}) ->
            ?LOG_DEBUG(
                "update to ~w, ~w ~w",
                [Edge_Dst, State#state.phase, Component]
            ),
            events:tick(),
            send(Edge_Dst, {update, Component, State#state.phase})
        end,
        New_Children
    ),
    New_Node =
        if
            Component#component.core == Node#node.id ->
                Node#node{parent = none, 
                          children = [Candidate#candidate.edge | New_Children]
                          };
            true ->
                Node#node{parent = Candidate#candidate.edge, 
                          children = New_Children
                          }
        end,
    New_State =
        State#state{
            replies = 0,
            candidate = none,
            selected = false
        },
    case New_State#state.phase of
        searching ->
            search(New_Node, New_State, Component);
        _ ->
            node_loop(New_Node, New_State, Component)
    end.


broadcast(#node{children = []} = Node, State, Component) ->
    convergecast(
        Node,
        State#state{replies = 0, representative = pid_to_list(Node#node.id)},
        Component
    );

broadcast(Node, State, Component) ->
    events:tick(),
    lists:foreach(fun(#edge{dst = Edge_Dst}) -> 
                      send(Edge_Dst, broadcast)
                  end, Node#node.children),
    node_loop(
        Node, State#state{replies = 0, representative = pid_to_list(Node#node.id)}, Component
    ).


% compute MST weight
% calculate minimax routing tables
convergecast(#node{parent = none} = Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    root_action(Node, State, Component),
    done_action(State#state.supervisor),
    node_loop(Node, State, Component);

convergecast(Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    ?LOG_DEBUG("~p", [Node#node.minimax_routing_table]),
    Rev_Parent_Edge = reverse_edge(Node#node.parent),
    Msg = {convergecast, State#state.representative, State#state.sum + Node#node.parent#edge.weight,
            maps:merge(
                maps:from_keys(maps:keys(Node#node.minimax_routing_table), Rev_Parent_Edge),
                #{Node#node.id => Rev_Parent_Edge}
            )},
    events:tick(),
    send(Node#node.parent#edge.dst, Msg),
    done_action(State#state.supervisor),
    node_loop(Node, State, Component);

convergecast(Node, State, Component) ->
    node_loop(Node, State, Component).




% UTILS

reverse_edge(#edge{dst = Dst, src = Src} = Edge) ->
    Edge#edge{dst = Src, src = Dst}.

list(none) ->
    [];
list(A) ->
    [A].

min(Fun, A, B) ->
    case Fun(A, B) of
        true ->
            A;
        false ->
            B
    end.

compare_edge(_, none) ->
    true;
compare_edge(none, _) ->
    false;
compare_edge(A_Edge, B_Edge) ->
    {
        A_Edge#edge.weight,
        min(A_Edge#edge.src, A_Edge#edge.dst),
        max(A_Edge#edge.src, A_Edge#edge.dst)
    } =<
        {
            B_Edge#edge.weight,
            min(B_Edge#edge.src, B_Edge#edge.dst),
            max(B_Edge#edge.src, B_Edge#edge.dst)
        }.

compare_candidate(_, none) ->
    true;
compare_candidate(none, _) ->
    false;
compare_candidate(#candidate{edge = A_Edge}, #candidate{edge = B_Edge}) ->
    compare_edge(A_Edge, B_Edge).



% modification of erlang:send function

send(To, Msg) ->
    LatencySendFun = fun (To2, Msg2) -> latency:send(To2, Msg2, ?LATENCY) end,
    events:send(To, Msg, LatencySendFun).


% function for logging events

save_event(Event) when is_map(Event) ->
    JsonString = jsone:encode(Event),
    asynch_write:write(JsonString).


% sanitize pids and timestamps as json strings

pid_to_json(Pid) -> 
    erlang:list_to_binary(erlang:pid_to_list(Pid)).

timestamp_to_json(Time) ->
    L = maps:to_list(Time),
    L2 = lists:map(fun ({Key, Value}) -> {pid_to_json(Key), Value} end, L),
    maps:from_list(L2).


% node/link initialization

save_node(At, X, Y) when is_pid(At) andalso is_number(X) andalso is_number(Y) ->
    Event = #{at => At, x => X, y => Y},
    save_event(Event).

save_link(From, To, Weight) when is_pid(From) andalso is_pid(To) andalso is_number(Weight) ->
    Event = #{from => From, to => To, weight => Weight},
    save_event(Event).


% callback functions for process state, link state, and messages

on_process_state(Pid, OldState, NewState, _Time, VClock) ->
    case NewState of
        OldState -> 
            ok;
        {Tag, Level} ->
            % Event = #{tag => Tag, at => Pid, level => Level, from_time => Time, to_time => Time + ?LATENCY},
            Event = #{tag => Tag, at => Pid, level => Level, time => timestamp_to_json(VClock)},
            save_event(Event)
    end.

on_link_state(From, To, OldState, NewState, _Time, VClock) ->
    case NewState of
        OldState -> 
            ok;
        Tag ->    
            % Event = #{tag => Tag, from => From, to => To, from_time => Time, to_time => Time + ?LATENCY},
            Event = #{tag => Tag, from => From, to => To, time => timestamp_to_json(VClock)},
            save_event(Event)
    end.

on_message(From, To, Msg, _FromState, _ToState, _FromTime, _ToTime, FromVClock, ToVClock) -> 
    if
        is_tuple(Msg) -> 
            Tag = element(1, Msg);
        is_atom(Msg) -> 
            Tag = Msg
    end,
    % Event = #{tag => Tag, from => From, to => To, from_time => FromTime, to_time => ToTime},
    Event = #{tag => Tag, from => From, to => To, from_time => timestamp_to_json(FromVClock), to_time => timestamp_to_json(ToVClock)},
    save_event(Event).

