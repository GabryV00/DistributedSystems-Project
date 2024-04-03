-module(ghs).

-behaviour(events).
-export([on_process_state/5, on_link_state/6, on_message/9]).

-include_lib("stdlib/include/assert.hrl").
-include_lib("kernel/include/logger.hrl").

%% API
-export([start_link/1]).

%% MACROS
-define(LOG_FILENAME, "logs/ghs.txt").
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
    adjs = [] :: [#edge{}],
    minimax_routing_table = #{} :: #{pid() => #edge{}},
    pid_to_name = #{} :: #{pid() => term()}
}).
-record(component, {core :: pid(), level = 0 :: non_neg_integer()}).
-record(candidate, {source_id :: pid(), edge :: #edge{}}).
-record(state, {
    name :: term(),
    mst_session :: non_neg_integer(),
    phase :: searching | found,
    replies = 0 :: non_neg_integer(),
    candidate = none :: #candidate{} | none,
    selected = false :: boolean(),
    supervisor :: pid(),
    representative = none :: nonempty_string() | none,
    sum = 0 :: non_neg_integer()
}).


start_link(Name) ->
    logger:set_module_level(?MODULE, error),
    Pid = spawn_link(fun() -> node_start(Name, Name) end),
    {ok, Pid}.



%% RESERVED

% supervise(N) ->
%     supervise(N, []).

% supervise(N, Components) when N > 0 ->
%     ?LOG_DEBUG("(supervisor) N = ~p", [N]),
%     receive
%         {component, C} ->
%             supervise(N, [C | Components]);
%         {done} ->
%             supervise(N - 1, Components)
%     end;

% supervise(0, Components) ->
%     String = lists:foldl(
%         fun({Representative, Sum}, Acc) ->
%             case Acc of
%                 "" -> Sep = "";
%                 _ -> Sep = ", "
%             end,
%             lists:flatten([
%                 Acc,
%                 io_lib:format("~s[\"~s\", ~w]", [Sep, Representative, Sum])
%             ])
%         end,
%         "",
%         Components
%     ),
%     % datagraph:fwrite_partial_graph(standard_io, Graph)
%     % TO BE DONE: EXPORT SPANNING TREE
%     io:fwrite(standard_io, "\"components\": [~s]}", [String]).


root_action(Node, #state{representative = none} = State, Component) ->
    broadcast(Node, State, Component);

root_action(Node, State, _Component) ->
    ?LOG_DEBUG("(~p, ~p) ~p", [State#state.name, State#state.mst_session, Node#node.minimax_routing_table]),
    State#state.supervisor ! {component, {State#state.representative, State#state.sum}}.


done_action(Supervisor, State, Node) ->
    ?LOG_DEBUG("(~p, ~p) done to ~w", [State#state.name, State#state.mst_session, Supervisor]),
    TranslationFun = fun (X) ->
                             case X of
                                 Pid when is_pid(Pid) andalso Pid == Node#node.id ->
                                     State#state.name;
                                 Pid when is_pid(Pid) ->
                                     maps:get(Pid, Node#node.pid_to_name, Pid);
                                 #edge{dst = Dst, weight = Weight} ->
                                     #edge{src = State#state.name,
                                           dst = maps:get(Dst, Node#node.pid_to_name),
                                           weight = Weight}
                             end
                     end,
    case Node#node.parent of
        none = Parent ->
            ok;
        ParentEdge ->
            Parent = TranslationFun(ParentEdge)
    end,
    RoutingTable = translate_map(maps:iterator(Node#node.minimax_routing_table), TranslationFun),
    Supervisor ! {done, {State#state.mst_session, Parent, RoutingTable}}.


translate_map(Iterator, TranslationFun) ->
    translate_map(#{}, maps:next(Iterator), TranslationFun).
translate_map(Map, {Key, Value, NextIterator}, TranslationFun) ->
    NewKey = TranslationFun(Key),
    NewValue = TranslationFun(Value),
    translate_map(Map#{NewKey => NewValue}, maps:next(NextIterator), TranslationFun);
translate_map(Map, none, _) ->
    Map.


unreachable_action(#state{supervisor = Supervisor} = State, Node, Component, To) ->
    ?LOG_DEBUG("(~p) sending {unreachable, ~p} to supervisor", [State#state.name, To]),
    Supervisor ! {unreachable, State#state.mst_session, To},
    % node_start(Supervisor, State#state.name),
    node_loop(Node, State, Component).

node_start(Supervisor, Name) ->
    receive
        {SessionID, {change_adjs, Adjs}} ->
            SortedAdjs = lists:sort(fun compare_edge/2, Adjs),
            search(
                #node{id = self(), undecided = SortedAdjs, adjs = SortedAdjs, pid_to_name = #{}},
                #state{name = Name, mst_session = SessionID, supervisor = Supervisor, phase = searching},
                #component{level = 0, core = self()}
            );
        {info, {From, get_state}} ->
            From ! {self(), not_computing},
            node_start(Supervisor, Name)
    end.
    % events:process_state({core, 0}),

node_start(Supervisor, Name, CurrentSession) ->
    receive
        {SessionID, {change_adjs, Adjs}} when SessionID >= CurrentSession ->
            SortedAdjs = lists:sort(fun compare_edge/2, Adjs),
            search(
                #node{id = self(), undecided = SortedAdjs, adjs = SortedAdjs, pid_to_name = #{}},
                #state{name = Name, mst_session = SessionID, supervisor = Supervisor, phase = searching},
                #component{level = 0, core = self()}
            );
        {info, {From, get_state}} ->
            From ! {self(), not_computing},
            node_start(Supervisor, Name, CurrentSession)
    end.


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
        {timeout, To} ->
            ?LOG_DEBUG("(~p) Request to ~p timed out", [State#state.name, To]),
            unreachable_action(State, Node, Component, To);
        {info, {From, get_state}} ->
            From ! {self(), [Node, State, Component]},
            node_loop(Node, State, Component);
        {SessionID, {change_adjs, Adjs}} when SessionID > State#state.mst_session ->
            ?assert(SessionID >= State#state.mst_session),
            ?LOG_DEBUG("(~p, ~p) got change_adjs, SessionID=~p, My SessionID=~p", [State#state.name, State#state.mst_session, SessionID, State#state.mst_session]),
            events:tick(),
            SortedAdjs = lists:sort(fun compare_edge/2, Adjs),
            search(
              #node{id = self(), undecided = SortedAdjs, adjs = SortedAdjs},
              #state{name = State#state.name,
                     phase = searching,
                     supervisor = State#state.supervisor,
                     mst_session = SessionID},
              #component{level = 0, core = self()}
             );
        {{_NameFrom, _PidFrom, _AckTo, _Ref, {SessionID, _}}, _Annot} = Msg when SessionID > State#state.mst_session ->
            ?LOG_DEBUG("(~p, ~p) got a message with SessionID=~p while mine is ~p", [State#state.name, State#state.mst_session,SessionID, State#state.mst_session]),
            self() ! Msg, % re-send the message to be consumed later
            node_start(State#state.supervisor, State#state.name, SessionID);
        {{_NameFrom, _PidFrom, AckTo, Ref, {SessionID, _}}, _Annot} when SessionID < State#state.mst_session ->
            send_ack(self(), AckTo, Ref),
            node_loop(Node, State, Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {test, Source_Id, Source_Component}}}, _} = Msg when Component#component.level >= Source_Component#component.level ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) test from ~w, ~w", [State#state.name, State#state.mst_session, Source_Id, Source_Component]),
            test(NewNode, State, Component, Source_Id, Source_Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, accept}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) got accept", [State#state.name, State#state.mst_session]),
            ?assertEqual(
                searching,
                State#state.phase,
                io_lib:format("accept received in ~p phase", [State#state.phase])
            ),
            Candidate = #candidate{source_id = Node#node.id, edge = hd(Node#node.undecided)},
            report(
                NewNode,
                State#state{
                    replies = State#state.replies + 1,
                    candidate =
                        min(fun compare_candidate/2, State#state.candidate, Candidate)
                },
                Component
            );
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, reject}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            ?LOG_DEBUG("(~p, ~p) got reject", [State#state.name, State#state.mst_session]),
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
                    rejected = [hd(Node#node.undecided) | Node#node.rejected],
                    pid_to_name = PidToName#{PidFrom => NameFrom}
                },
                State,
                Component
            );
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {report, Candidate}}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) got report, ~w", [State#state.name, State#state.mst_session, Candidate]),
            ?assertEqual(
                searching,
                State#state.phase,
                io_lib:format("report received in ~p phase", [State#state.phase])
            ),
            report(
                NewNode,
                State#state{
                    replies = State#state.replies + 1,
                    candidate =
                        min(fun compare_candidate/2, State#state.candidate, Candidate)
                },
                Component
            );
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, notify}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) got notify", [State#state.name, State#state.mst_session]),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("notify received in ~p phase", [State#state.phase])
            ),
            notify(NewNode, State, Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {merge, Source_Id, Source_Level}}}, _} = Msg when Component#component.level > Source_Level ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) merge (quick) from ~w, ~w", [State#state.name, State#state.mst_session, Source_Id, Source_Level]),
            merge(NewNode, State, Component, Source_Id, Source_Level);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {merge, Source_Id, Source_Level}}}, _} = Msg when Component#component.level == Source_Level andalso
                                                         State#state.selected andalso
                                                         State#state.candidate#candidate.edge#edge.dst == Source_Id ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) merge from ~w, ~w", [State#state.name, State#state.mst_session, Source_Id, Source_Level]),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("merge (slow) received in ~p phase", [State#state.phase])
            ),
            merge(NewNode, State, Component, Source_Id, Source_Level);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {update, New_Component, Phase}}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) got update, ~w ~w", [State#state.name, State#state.mst_session, New_Component, Phase]),
            ?assertEqual(
                found,
                State#state.phase,
                io_lib:format("update received in ~p phase", [State#state.phase])
            ),
            update(NewNode, State#state{phase = Phase}, New_Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, broadcast}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            broadcast(NewNode, State, Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {convergecast, Source_Representative, Source_Sum, Minimax_Routing_Table, PidToNameFrom}}}, _} = Msg -> events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            NewPidToName = maps:merge((Node#node.pid_to_name)#{PidFrom => NameFrom}, PidToNameFrom),
            convergecast(
                Node#node{
                    minimax_routing_table = maps:merge(
                        Node#node.minimax_routing_table, Minimax_Routing_Table
                    ),
                    pid_to_name = NewPidToName
                },
                State#state{
                    replies = State#state.replies + 1,
                    representative = max(State#state.representative, Source_Representative),
                    sum = State#state.sum + Source_Sum
                },
                Component
            );
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {route, Dst, Dist}}}, _} = Msg when Dst == Node#node.id ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            ?LOG_DEBUG("(~p, ~p) got long distance ~p", [State#state.name, State#state.mst_session, Dist]),
            node_loop(NewNode, State, Component);
        {{NameFrom, PidFrom, AckTo, Ref, {_SessionID, {route, Dst, _}}}, _} = Msg ->
            events:received_annotated_msg(Msg),
            send_ack(self(), AckTo, Ref),
            PidToName = Node#node.pid_to_name,
            NewNode = Node#node{pid_to_name = PidToName#{PidFrom => NameFrom}},
            Next_Hop_Edge = maps:get(Dst, Node#node.minimax_routing_table, Node#node.parent),
            events:tick(),
            send_wait_ack(State#state.name, Next_Hop_Edge#edge.dst, Msg),
            node_loop(NewNode, State, Component);
        {{_, AckTo, Ref, {_, _}, _}} ->
            send_ack(self(), AckTo, Ref),
            node_loop(Node, State, Component)
    end.


test(Node, State, Component, Source_Id, #component{core = Source_Core}) ->
    case Component#component.core of
        Source_Core ->
            ?LOG_DEBUG("(~p, ~p) reject to ~w", [State#state.name, State#state.mst_session, Source_Id]),
            events:tick(),
            send_wait_ack(State#state.name, Source_Id, {State#state.mst_session, reject});
        _ ->
            ?LOG_DEBUG("(~p, ~p) accept to ~w", [State#state.name, State#state.mst_session, Source_Id]),
            events:tick(),
            send_wait_ack(State#state.name, Source_Id, {State#state.mst_session, accept})
    end,
    node_loop(Node, State, Component).


search(#node{undecided = [Edge | _]} = Node, State, Component) ->
    ?LOG_DEBUG("(~p, ~p) test to ~w, ~w", [State#state.name, State#state.mst_session, Edge#edge.dst, Component]),
    events:tick(),
    send_wait_ack(State#state.name, Edge#edge.dst, {State#state.mst_session, {test, Node#node.id, Component}}),
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
        "(~p, ~p) report to ~w, ~w",
        [State#state.name, State#state.mst_session, Node#node.parent#edge.dst, Reported_Candidate]
    ),
    events:tick(),
    send_wait_ack(State#state.name, Node#node.parent#edge.dst, {State#state.mst_session, {report, Reported_Candidate}}),
    node_loop(Node, State#state{phase = found}, Component);

report(Node, State, Component) ->
    node_loop(Node, State, Component).


notify(Node, #state{candidate = Candidate} = State, Component) when Candidate#candidate.source_id == Node#node.id ->
    ?LOG_DEBUG(
        "(~p, ~p) merge to ~w, ~w",
        [State#state.name, State#state.mst_session, Candidate#candidate.edge#edge.dst, Component#component.level]
    ),
    events:tick(),
    send_wait_ack(State#state.name, Candidate#candidate.edge#edge.dst, {State#state.mst_session, {merge, Node#node.id, Component#component.level}}),
    node_loop(Node#node{undecided = tl(Node#node.undecided)}, State#state{selected = true}, Component);   % modified to avoid testing again the core edge

notify(Node, #state{candidate = Candidate} = State, Component) ->
    {[Source_Edge], Children} =
        lists:partition(
            fun(Edge) -> Edge#edge.dst == Candidate#candidate.source_id end,
            Node#node.children
        ),
    ?LOG_DEBUG("(~p, ~p) notify to ~w", [State#state.name, State#state.mst_session, Source_Edge#edge.dst]),
    events:tick(),
    send_wait_ack(State#state.name, Source_Edge#edge.dst, {State#state.mst_session, notify}),
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
    ?LOG_DEBUG("(~p, ~p) update to ~w, ~w ~w", [State#state.name, State#state.mst_session, Source_Id, State#state.phase, Component]),
    events:tick(),
    send_wait_ack(State#state.name, Source_Id, {State#state.mst_session, {update, Component, State#state.phase}}),
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
    ?LOG_DEBUG("(~p, ~p) update to ~w, ~w ~w", [State#state.name, State#state.mst_session, Source_Id, searching, New_Component]),
    events:tick(),
    send_wait_ack(State#state.name, Source_Id, {State#state.mst_session, {update, New_Component, searching}}),
    node_loop(Node, State, Component).


update(Node, #state{selected = false} = State, Component) ->
    lists:map(
        fun(#edge{dst = Edge_Dst}) ->
            ?LOG_DEBUG(
                "(~p, ~p) update to ~w, ~w ~w",
                [State#state.name, State#state.mst_session, Edge_Dst, State#state.phase, Component]
            ),
            events:tick(),
            send_wait_ack(State#state.name, Edge_Dst, {State#state.mst_session, {update, Component, State#state.phase}})
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
                "(~p, ~p) update to ~w, ~w ~w",
                [State#state.name, State#state.mst_session, Edge_Dst, State#state.phase, Component]
            ),
            events:tick(),
            send_wait_ack(State#state.name, Edge_Dst, {State#state.mst_session, {update, Component, State#state.phase}})
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
                          send_wait_ack(State#state.name, Edge_Dst, {State#state.mst_session, broadcast})
                  end, Node#node.children),
    node_loop(
        Node, State#state{replies = 0, representative = pid_to_list(Node#node.id)}, Component
    ).


% compute MST weight
% calculate minimax routing tables
convergecast(#node{parent = none} = Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    root_action(Node, State, Component),
    done_action(State#state.supervisor, State, Node),
    node_loop(Node, State, Component);

convergecast(Node, State, Component) when State#state.replies == ?Expected_replies(Node) ->
    ?LOG_DEBUG("(~p, ~p) ~p", [State#state.name, State#state.mst_session, Node#node.minimax_routing_table]),
    Rev_Parent_Edge = reverse_edge(Node#node.parent),
    Msg = {convergecast, State#state.representative, State#state.sum + Node#node.parent#edge.weight,
            maps:merge(
                maps:from_keys(maps:keys(Node#node.minimax_routing_table), Rev_Parent_Edge),
                #{Node#node.id => Rev_Parent_Edge}
            ),
            Node#node.pid_to_name
          },
    events:tick(),
    send_wait_ack(State#state.name, Node#node.parent#edge.dst, {State#state.mst_session, Msg}),
    done_action(State#state.supervisor, State, Node),
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

send_wait_ack(From, To, Msg) ->
    admin ! {self(), timer},
    receive
        {admin, Timeout} -> ok
    end,
    send_wait_ack(From, To, Msg, Timeout).
send_wait_ack(From, To, Msg, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> wait_acknowledgement(To, Msg, Ref, Parent, Timeout) end),
    send(To, {From, self(), Pid, Ref, Msg}).



wait_acknowledgement(Destination, Msg, Ref, Parent, Timeout) ->
    receive
        {Destination, Ref, ack} ->
            Parent ! {acknowledged, Destination}
        after Timeout ->
            % ?LOG_DEBUG("Didn't get ack for ~p", [Msg]),
            Parent ! {timeout, Destination}
    end.



send_ack(From, To, Ref) ->
    To ! {From, Ref, ack}.


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

