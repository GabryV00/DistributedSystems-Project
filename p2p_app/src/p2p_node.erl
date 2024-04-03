%%%-------------------------------------------------------------------
%%% @author  <gianluca>
%%% @copyright (C) 2024,
%%% @doc
%%%
%%% @end
%%% Created: 24 March 2024
%%%-------------------------------------------------------------------
-module(p2p_node).
-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/2, join_network/2, get_state/1,
         request_to_communicate/3, leave_network/1, close_connection/2,
         init_node_from_file/1, start_mst_computation/1]).

-define(CONFIG_DIR, "../src/init/config_files/").
-define(SERVER, ?MODULE).

% childspecs to be used with supervisor:start_child() to ask the supervisor to
% start a new worker
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

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Extract node information (id, edges) from config file and start a node
%% by asking the supervisor
%% @param FileName A JSON encoded file with the node's data
%% @end
init_node_from_file(FileName) ->
    try
        {ok, Json} = file:read_file(FileName),
        Data = jsone:decode(Json),
        Id = utils:get_pid_from_id(maps:get(<<"id">>, Data)),
        Edges = utils:build_edges(Id, maps:get(<<"edges">>, Data)),
        p2p_node_manager:spawn_node(Id, []),
        ?LOG_DEBUG("Node ~p started from file ~p", [Id, FileName]),
        {Id, Edges}
    catch
        error:{Reason, _Stack} ->
            ?LOG_ERROR("Error: ~p during init on file ~p", [Reason, FileName])
    end.

request_to_communicate(From, To, Band) ->
    gen_server:call(From, {request_to_communicate, From, To, Band}).

close_connection(From, To) ->
    gen_server:call(From, {close_connection, To}).

% start_stream(To) ->
%     gen_server:call(self(), {start_stream, To}).

% end_stream(To) ->
%     gen_server:call(self(), {end_stream, To}).

% send_data(From, To) ->
%     todo.

start_mst_computation(Ref) ->
    gen_server:call(Ref, start_mst).

leave_network(Ref) ->
    try
        gen_server:call(Ref, leave)
    catch
        exit:{timeout, _Location} ->
            exit(Ref, shutdown);
        exit:{noproc, _Location} ->
            ok;
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [Ref])
    end.


join_network(Ref, Adjs) when is_atom(Ref) ->
    try
        validate_edges(Ref, Adjs),
        Reply = gen_server:call(Ref, {join, Adjs}),
        case Reply of
            ok -> ok;
            _ -> todo
        end
    catch
        throw:edges_not_valid ->
            ?LOG_ERROR("Edges are not valid");
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to join to ~p timed out");
        exit:{noproc, _Location} ->
            p2p_node_manager:spawn_node(Ref, Adjs),
            join_network(Ref, Adjs);
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [Ref])
    end;

join_network(_Ref, _) ->
    throw(name_not_valid).

get_state(Ref) ->
    gen_server:call(Ref, get_state).




%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(Args :: term()) -> {ok, Pid :: pid()} |
	  {error, Error :: {already_started, pid()}} |
	  {error, Error :: term()} |
	  ignore.
start_link([Name | _] = Args) ->
    gen_server:start_link({local, Name}, ?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
	  {ok, State :: term(), Timeout :: timeout()} |
	  {ok, State :: term(), hibernate} |
	  {stop, Reason :: term()} |
	  ignore.
init([Name, Adjs, Supervisor]) ->
    process_flag(trap_exit, true),
    logger:set_module_level(?MODULE, debug),

    ?LOG_DEBUG("(~p) Starting node with adjs ~p", [Name, Adjs]),

    State = #state{
          name = Name,
          adjs = Adjs,
          mst_adjs = [],
          supervisor = Supervisor,
          current_mst_session = 0,
          mst_state = undefined,
          mst_computer_pid = undefined
         },

    % dump_config(State),
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
	  {reply, Reply :: term(), NewState :: term()} |
	  {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
	  {reply, Reply :: term(), NewState :: term(), hibernate} |
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: term(), Reply :: term(), NewState :: term()} | {stop, Reason :: term(), NewState :: term()}.
%% Get the state of the peer
handle_call(get_state = Req, _, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    {reply, State, State};
%% Join the network by notifying the nodes in Adjs
handle_call({join, Adjs} = Req, _From, #state{name = Name, supervisor = Supervisor, mst_computer_pid = MstComputerPid} = State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    % Get a process to compute the MST from the supervisor
    MstComputer = get_mst_worker(Name, MstComputerPid, Supervisor),
    % Ask the neighbors for the pid of their MST process
    MstAdjsTemp = get_neighbors_mst_pid(Adjs, Name, MstComputer),
    ?LOG_DEBUG("(~p) Mst Pid of neighbors ~p", [State#state.name, MstAdjsTemp]),
    MstAdjs = proplists:get_all_values(ok, MstAdjsTemp),
    ?LOG_DEBUG("(~p) Mst Pid of neighbors who answered ~p", [State#state.name, MstAdjs]),
    Unreachable = proplists:get_all_values(timed_out, MstAdjsTemp),
    % Update the neighbor list
    NewAdjs = lists:subtract(Adjs, Unreachable),
    NewState = State#state{
                 adjs = NewAdjs,
                 mst_computer_pid = MstComputer,
                 mst_adjs = MstAdjs},
    % dump_config(NewState),
    {reply, ok, NewState};
%% A new neighbor appeared and asks to join the network
handle_call({new_neighbor, NeighborName, Weight, MstPid} = Req, _NodeFrom,
            #state{name = Name, adjs = Adjs, mst_computer_pid = Pid, mst_adjs = MstAdjs} = State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Supervisor = State#state.supervisor,
    % Get a process to compute the MST, if it doesn't already exist
    MstComputer = get_mst_worker(Name, Pid, Supervisor),

    case lists:keyfind(MstPid, 2, MstAdjs) of
         false ->
            NewMstAdjs = [#edge{src = MstComputer, dst = MstPid, weight = Weight} | MstAdjs];
         _ ->
            NewMstAdjs = MstAdjs
    end,

    case lists:keyfind(NeighborName, 2, Adjs) of
         false ->
            NewAdjs = [#edge{src = Name, dst = NeighborName, weight = Weight} | Adjs];
         _ ->
            NewAdjs = Adjs
    end,

    NewState = State#state{
                 mst_adjs = NewMstAdjs,
                 adjs = NewAdjs,
                 mst_computer_pid = MstComputer
                },
    % Reply to the neighbor with the pid of the MST process
    % dump_config(NewState),
    {reply, MstComputer, NewState};
handle_call(start_mst, _From, #state{name = Name,
                                     adjs = Adjs,
                                     mst_adjs = MstAdjs,
                                     mst_computer_pid = MstComputer} = State) ->
    % Get a new MST session ID from the Admin, this will be used to compute the MST
    SessionID = get_new_session_id(),
    % Notify neighbors and start to compute the MST
    start_mst_computation(Name, Adjs, MstAdjs, MstComputer, SessionID),
    {reply, ok, State#state{mst_state = computing}};
%% Request to communicate from source node perspective
handle_call({request_to_communicate, Who, To, Band} = Req, _From, State) when State#state.mst_state == computed andalso Who == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    #edge{dst = NextHop, weight = Weight} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
    case Weight >= Band of
        true ->
            try
                case gen_server:call(NextHop, {request_to_communicate, Who, To, Band, ConnHandlerPid}, 10000) of
                    {ok, NextHopConnHandler} ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, Who, To),
                        CurrentConnections = State#state.connections,
                        CurrentConnHandlers = State#state.conn_handlers,
                        NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                               conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid}},
                        {reply, {ok, ConnHandlerPid}, NewState};
                    _ ->
                        todo
                end
            catch
                exit:{timeout, _} -> todo
            end;
        false ->
            {reply, no_band, State}
    end;
%% Request to communicate from destination node perspective
handle_call({request_to_communicate, Who, To, Band, LastHop} = Req, _From, State) when State#state.mst_state == computed andalso To == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    p2p_conn_handler:talk_to(ConnHandlerPid, LastHop, Who, To),
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = [{Who, To} | CurrentConnections],
                           conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid}},
    {reply, {ok, ConnHandlerPid}, NewState};
%% Request to communicate from intermediate node perspective
handle_call({request_to_communicate, Who, To, Band, LastHop} = Req, _From, State) when State#state.mst_state == computed andalso To /= State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    #edge{dst = NextHop, weight = Weight} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
    case Weight >= Band of
        true ->
            try
                case gen_server:call(NextHop, {request_to_communicate, Who, To, Band}, 10000) of
                    {ok, NextHopConnHandler} ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, LastHop, Who, To),
                        CurrentConnections = State#state.connections,
                        CurrentConnHandlers = State#state.conn_handlers,
                        NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                               conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid}},
                        {reply, {ok, ConnHandlerPid}, NewState};
                    _ ->
                        todo
                end
            catch
                exit:{timeout, _} -> todo
            end;
        false ->
            {reply, no_band, State}
    end;
%% Request to communicate when MST is not computed from node's perspective
handle_call({request_to_communicate, _, _, _} = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p but no info on MST", [State#state.name, Req]),
    {reply, no_mst, State};
handle_call(leave = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Reason = normal,
    Reply = ok,
    {stop, Reason, Reply, State};
handle_call(Request, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p, not managed", [State#state.name, Request]),
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: term(), NewState :: term()}.
%% When this message is received, someone wants to start computing the MST
%% The request is only considered if it comes from someone with a greater SessionID
%% than the one known by the node
handle_cast({awake, NameFrom, SessionID} = Req, #state{current_mst_session = CurrentMstSession} = State) when SessionID > CurrentMstSession ->
    ?LOG_DEBUG("(~p) got (cast) ~p", [State#state.name, Req]),
    Name = State#state.name,
    Adjs = State#state.adjs,
    MstComputer = State#state.mst_computer_pid,
    MstAdjs = State#state.mst_adjs,
    % Awake all neighbors informing them of the new SessionID (not the one from
    % which the message came from)
    ToAwake = lists:filter(fun(#edge{dst = Dst}) ->
                                   Dst =/= NameFrom
                           end , Adjs),
    % Start to compute the MST using the new SessionID
    start_mst_computation(Name, ToAwake, MstAdjs, MstComputer, SessionID),
    {noreply, State#state{current_mst_session = SessionID, mst_state=computing}};
handle_cast(_Request, State) ->
    % ?LOG_DEBUG("(~p) got (cast) ~p, not managed", [State#state.name, Request]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: normal | term(), NewState :: term()}.
handle_info({done, {SessionID, MstParent, MstRoutingTable}} = Msg, State) when SessionID >= State#state.current_mst_session ->
    ?LOG_DEBUG("(~p) got ~p from my MST computer", [State#state.name, Msg]),
    NewState = State#state{current_mst_session = SessionID,
                           mst_state = computed,
                           mst_parent = MstParent,
                           mst_routing_table = MstRoutingTable},
    {noreply, NewState};
handle_info({unreachable, SessionID, Who} = Msg, State) when SessionID >= State#state.current_mst_session ->
    ?LOG_DEBUG("(~p) got ~p from my MST computer", [State#state.name, Msg]),
    MstAdjs = State#state.mst_adjs,
    Adjs = State#state.adjs,
    MstEdgeToDelete = lists:keyfind(Who, 2, MstAdjs),

    case lists:keyfind(MstEdgeToDelete, 1, lists:zip(MstAdjs, Adjs)) of
        {_, EdgeToDelete} ->
            NewAdjs = lists:delete(EdgeToDelete, Adjs),
            NewMstAdjs = lists:delete(MstEdgeToDelete, MstAdjs);
        false ->
            NewAdjs = Adjs,
            NewMstAdjs = MstAdjs
    end,

    NewSessionID = get_new_session_id(),
    start_mst_computation(State#state.name, NewAdjs, NewMstAdjs, State#state.mst_computer_pid, NewSessionID),
    NewState = State#state{adjs = NewAdjs,
                           mst_adjs = NewMstAdjs,
                           current_mst_session = NewSessionID,
                           mst_state = computing},
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
		State :: term()) -> any().
terminate(_Reason, State) ->
    % Id = extract_id(State#state.name),
    % file:delete(?CONFIG_DIR ++ "node_" ++ Id ++ ".json"),
    try
        exit(State#state.mst_computer_pid, kill)
    catch
        error:_ -> ok % Mst process is already dead...
    end,
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
		  State :: term(),
		  Extra :: term()) -> {ok, NewState :: term()} |
	  {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
		    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
%% @doc Start the computation of a new MST
%% @param Name Is the name of the node starting the computation
%% @param Adjs Are the neighbors to inform of the new instance of the algorithm
%% @param MstAdjs Are the processes of the neighbors that manage the MST
%% @param MstComputerPid Is the pid of the process managing the MST of the node Name
%% @param SessionID Is the session of the MST
%% @end
start_mst_computation(Name, Adjs, MstAdjs, MstComputerPid, SessionID) ->
    lists:foreach(fun(#edge{dst = Dst}) ->
                          ?LOG_DEBUG("~p awakening node ~p", [Name, Dst]),
                          timer:sleep(10), % introducing latency
                          gen_server:cast(Dst, {awake, Name, SessionID})
                  end,
                  Adjs),
    MstComputerPid ! {SessionID, {change_adjs, MstAdjs}}.



%% @private
%% @doc Get the current or a new process to compute the MST
%% @param Name Is the name of the node
%% @param Current Is the MST process
%% @param Supervisor Is the supervisor's pid who can provide a new MST process if needed
%% @end
get_mst_worker(Name, Current, Supervisor) ->
    case Current of
        undefined ->
            {ok, New} = p2p_node_sup:start_mst_worker(Supervisor, Name),
            New;
        _Pid ->
            Current
    end.

%% @private
%% @doc Get a fresh SessionID to compute the MST
%% @end
get_new_session_id() -> get_new_session_id(3).
get_new_session_id(Times) when Times > 0 ->
    admin ! {self(), new_id},
    receive
        {admin, Id} ->
        Id
    after 2000 ->
        get_new_session_id(Times - 1)
    end;
get_new_session_id(0) -> throw(timeout).

%% @private
%% @doc Get the State of the MST process
%% @param MstComputer Is the MST process
%% @end
get_mst_info(MstComputer) ->
    MstComputer ! {info, {self(), get_state}},
    receive
        {MstComputer, Info} ->
            Info
    end.


dump_config(State) ->
    [_ , Id] = extract_id(State#state.name),
    Edges = lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                            [_, DstId] = extract_id(Dst),
                            [list_to_integer(DstId), Weight]
                      end, State#state.adjs),
    Json = jsone:encode(#{<<"id">> => list_to_bitstring(Id), <<"edges">> => Edges}),

    file:write_file(?CONFIG_DIR ++ "node_" ++ Id ++ ".json", Json).


extract_id(Name) ->
    string:split(atom_to_list(Name), "node").


validate_edges(Ref, Edges) ->
    try
        lists:all(fun(#edge{src = Src, dst = Dst, weight = Weight}) ->
                      (is_atom(Src) or is_pid(Src)) andalso
                      (is_atom(Dst) or is_pid(Dst)) andalso
                      is_number(Weight) andalso Weight > 0 andalso
                      Src == Ref andalso Dst /= Ref
                  end , Edges),
        ok
    catch
        _ -> throw(edges_not_valid)
    end.


get_neighbors_mst_pid(Adjs, Name, MstComputer) ->
    lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                      try
                          DstPid = gen_server:call(Dst, {new_neighbor, Name, Weight, MstComputer}),
                          {ok, #edge{src = MstComputer, dst = DstPid, weight = Weight}}
                      catch
                          exit:{timeout, _} -> {timed_out, Dst}
                      end
              end, Adjs).

get_connection_handler(SupRef) ->
    p2p_node_sup:start_connection_handler(SupRef).
