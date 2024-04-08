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
         init_node_from_file/1, start_mst_computation/1, send_data/3]).

-define(CONFIG_DIR, "../src/init/config_files/").
-define(SERVER, ?MODULE).

-record(edge, {dst :: pid(), src :: pid(), weight :: non_neg_integer()}).
-record(state, {
          name :: atom(),                                               % Name of the peer
          adjs = [] :: [#edge{}],                                       % List of incident edges, with other node names
          mst_adjs = [] :: [#edge{}],                                   % List of incident edges, pids of MST computers
          supervisor :: pid(),                                          % Pid of supervisor process
          current_mst_session :: non_neg_integer(),                     % Current session of stored MST
          connections = [] :: list(),                                   % List of tuples {From, To} that represents ongoing connections
          mst_computer_pid :: pid(),                                    % Pid of own MST computer
          mst_state = undefined :: computed | computing | undefined,    % Current state of MST from peer's perspective
          mst_routing_table = #{} :: #{atom() => #edge{}},              % MST routing table (map) in the form #{NodeName => Edge}
          mst_parent = none :: #edge{} | none,                          % Parent of peer in MST
          conn_handlers = #{} :: #{{term(), term()} => pid()}           % Connection handler pids for each connection. #{{From,To} => Pid}
         }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Extract node information (id, edges) from config file and start a node
%% by asking the supervisor
%% @param FileName A JSON encoded file with the node's data
%% @returns `{Id, Edges}', where Id is the nodeId (atom) extracted from the file
%% and Edeges is a list of #edge records
%% @end
-spec init_node_from_file(FileName :: nonempty_string()) -> {Id :: term(), Edges :: [#edge{}]}.
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

%% @doc Request to communicate from a peer to another with a specified bandwidth
%% @param From The peer who starts the communication request
%% @param To The peer who receives the communication request
%% @param Band the minimum band needed for the communication
%% @returns `{ok, ConnHandlerPid}' if the request is successful
%%          `{timeout, NodeName}' if `NodeName' on the path to `To' times out on the request
%%          `{noproc, NodeName}' if `NodeName' doesn't exist on the path to `To'
%%          `{no_band, NodeName}' if the connection to `NodeName' on the path doesn't provide enough band
%% @end
-spec request_to_communicate(From :: pid(), To :: pid(), Band :: non_neg_integer() | float()) ->
    {ok, ConnHandlerPid :: pid()} |
    {timeout, NodeName :: pid()} |
    {noproc, NodeName :: pid()} |
    {no_band, NodeName :: pid()}.
request_to_communicate(From, To, Band) ->
    gen_server:call(From, {request_to_communicate, {From, To, Band}}).

%% @doc Closes the connection for both peers.
%% This is performed asynchronously, so there is no guarantee that all the
%% nodes in the path are reached.
%% @param From The peer who starts the closing request
%% @param To The peer who receives the closing request
%% @returns `ok' if the request is successful
%%          `{timeout, From}' if From didn't answer in time
%%          `{noproc, From}' if From doesn't exist
%%          `{shutdown, From}' if From has been shut down from it's supervisor
%% @end
-spec close_connection(From :: pid(), To :: pid()) ->
    ok |
    {timeout, From :: pid()} |
    {noproc, From :: pid()} |
    {shutdown, From :: pid()}.
close_connection(From, To) ->
    try
        gen_server:call(From, {close_connection, To})
    catch
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to join to ~p timed out"),
            {timeout, From};
        exit:{noproc, _Location} ->
            {noproc, From};
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [From]),
            {shutdown, From}
    end.

%% @doc From sends some binary data to To
%% This is performed asynchronously, so there is no guarantee that all the
%% nodes in the path are reached. Requires a connection established with request_to_communicate/3
%% @param From The peer who sends the data
%% @param To The peer who receives the data
%% @param Data Binary data to be sent
%% @returns `ok' if the request is successful
%%          `{no_connection, {From, To}}' if there is no active connection between the peers
%%          `{timeout, From}' if From didn't answer in time
%%          `{noproc, From}' if From doesn't exist
%%          `{shutdown, From}' if From has been shut down from it's supervisor
%% @end
-spec send_data(From :: pid(), To :: pid(), Data :: binary()) ->
    ok |
    {no_connection, {From :: pid(), To :: pid()}} |
    {timeout, From :: pid()} |
    {noproc, From :: pid()} |
    {shutdown, From :: pid()}.
send_data(From, To, Data) ->
    try
        gen_server:call(From, {send_data, From, To, Data})
    catch
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to join to ~p timed out"),
            {timeout, From};
        exit:{noproc, _Location} ->
            {noproc, From};
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [From]),
            {shutdown, From}
    end.

%% @doc Makes the node Ref start the computation of the MST by notifying it's neighbors
%% @param Ref The peer (pid or atom) who should start the algorithm
%% @returns `ok' if the request is successful
%%          `{timeout, Ref}' if Ref didn't answer in time
%%          `{noproc, Ref}' if Ref doesn't exist
%%          `{shutdown, Ref}' if Ref has been shut down from it's supervisor
%% @end
-spec start_mst_computation(Ref :: pid()) ->
    ok |
    {timeout, Ref :: pid()} |
    {noproc, Ref :: pid()} |
    {shutdown, Ref :: pid()}.
start_mst_computation(Ref) ->
    try
        gen_server:call(Ref, start_mst, get_timeout())
    catch
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to join to ~p timed out"),
            {timeout, Ref};
        exit:{noproc, _Location} ->
            {noproc, Ref};
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [Ref]),
            {shutdown, Ref}
    end.

%% @doc Makes the node Ref leave the network "gracefully"
%% Terminates also all the connection handlers and the MST computer of the peer
%% @param Ref The peer (pid or atom) who should leave the network
%% @returns `ok' if the request is successful
%%          `{timeout, Ref}' if Ref didn't answer in time
%%          `{noproc, Ref}' if Ref doesn't exist
%%          `{shutdown, Ref}' if Ref has been shut down from it's supervisor
%% @end
-spec leave_network(Ref :: pid()) ->
    ok |
    {timeout, Ref :: pid()} |
    {noproc, Ref :: pid()} |
    {shutdown, Ref :: pid()}.
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

%% @doc Instructs the peer to join the network with Adjs as neighbors
%% @param Ref The peer (pid or atom) who should join the network
%% @param Adjs List of #edge records with the other nodes' names
%% @returns `ok' if the request is successful
%%          `{timeout, Ref}' if Ref didn't answer in time
%%          `{noproc, Ref}' if Ref doesn't exist
%%          `{shutdown, Ref}' if Ref has been shut down from it's supervisor
%% @end
-spec join_network(Ref :: pid(), Adjs :: [#edge{}]) ->
    ok |
    {timeout, Ref :: pid()} |
    {noproc, Ref :: pid()} |
    {shutdown, Ref :: pid()}.
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
            ?LOG_ERROR("Edges are not valid"),
            {edges_not_valid, Adjs};
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to join to ~p timed out"),
            {timeout, Ref};
        exit:{noproc, _Location} ->
            p2p_node_manager:spawn_node(Ref, Adjs),
            join_network(Ref, Adjs);
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [Ref]),
            {shutdown, Ref}
    end;

join_network(_Ref, _) ->
    throw(name_not_valid).


%% @doc Inspects the state of the peer
%% @param Ref The peer (pid or atom) to inspect
%% @returns `#state' record if the request is successful
%%          `{timeout, Ref}' if Ref didn't answer in time
%%          `{noproc, Ref}' if Ref doesn't exist
%%          `{shutdown, Ref}' if Ref has been shut down from it's supervisor
%% @end
-spec get_state(Ref :: pid()) ->
    #state{} |
    {timeout, Ref :: pid()} |
    {noproc, Ref :: pid()} |
    {shutdown, Ref :: pid()}.
get_state(Ref) ->
    try
        gen_server:call(Ref, get_state)
    catch
        exit:{timeout, _Location} ->
            exit(Ref, shutdown);
        exit:{noproc, _Location} ->
            ok;
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [Ref])
    end.


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
    logger:set_module_level(?MODULE, error),

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
    Unreachable = proplists:get_all_values(timed_out, MstAdjsTemp) ++ proplists:get_all_values(noproc, MstAdjsTemp),
    % Update the neighbor list
    NewAdjs = lists:subtract(Adjs, Unreachable),
    NewState = State#state{
                 adjs = NewAdjs,
                 mst_computer_pid = MstComputer,
                 mst_adjs = MstAdjs},
    dump_config(NewState),
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
    dump_config(NewState),
    {reply, MstComputer, NewState};
handle_call(start_mst, _From, #state{name = Name,
                                     adjs = Adjs,
                                     mst_adjs = MstAdjs,
                                     mst_computer_pid = MstComputer} = State) ->
    % Get a new MST session ID from the Admin, this will be used to compute the MST
    SessionID = get_new_session_id(),
    % Notify neighbors and start to compute the MST
    start_mst_computation(Name, Adjs, MstAdjs, MstComputer, SessionID),
    {reply, ok, State#state{current_mst_session = SessionID, mst_state = computing}};
%% Request to communicate from source node perspective
handle_call({request_to_communicate, {Who, To, Band}} = Req, _From, State) when State#state.mst_state == computed andalso Who == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    #edge{dst = NextHop, weight = Weight} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
    case Weight >= Band of
        true ->
            try
                Timeout = get_timeout(),
                case gen_server:call(NextHop, {request_to_communicate, {Who, To, Band, ConnHandlerPid}}, Timeout) of
                    {ok, NextHopConnHandler} ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, Who, To),
                        CurrentConnections = State#state.connections,
                        CurrentConnHandlers = State#state.conn_handlers,
                        NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                               conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
                        {reply, {ok, ConnHandlerPid}, NewState};
                    Reply ->
                        exit(ConnHandlerPid, normal),
                        {reply, Reply, State}
                end
            catch
                exit:{timeout, _} ->
                    exit(ConnHandlerPid, normal),
                    {reply, {timeout, NextHop}, State};
                exit:{noproc, _} ->
                    exit(ConnHandlerPid, normal),
                    {reply, {noproc, NextHop}, State}
            end;
        false ->
            exit(ConnHandlerPid, normal),
            {reply, {no_band, {NextHop, Weight}}, State}
    end;
%% Request to communicate from destination node perspective
handle_call({request_to_communicate, {Who, To, _Band, LastHop}} = Req, _From, State) when State#state.mst_state == computed andalso To == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    p2p_conn_handler:talk_to(ConnHandlerPid, LastHop, Who, To),
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = [{Who, To} | CurrentConnections],
                           conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
    {reply, {ok, ConnHandlerPid}, NewState};
%% Request to communicate from intermediate node perspective
handle_call({request_to_communicate, {Who, To, Band, LastHop}} = Req, _From, State) when State#state.mst_state == computed andalso To /= State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    % TODO: manage parent = none and no next hop
    #edge{dst = NextHop, weight = Weight} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
    case Weight >= Band of
        true ->
            try
                Timeout = get_timeout(),
                case gen_server:call(NextHop, {request_to_communicate, {Who, To, Band, ConnHandlerPid}}, Timeout) of
                    {ok, NextHopConnHandler} ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, LastHop, Who, To),
                        CurrentConnections = State#state.connections,
                        CurrentConnHandlers = State#state.conn_handlers,
                        NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                               conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
                        {reply, {ok, ConnHandlerPid}, NewState};
                    Reply ->
                        exit(ConnHandlerPid, normal),
                        {reply, Reply, State}
                end
            catch
                exit:{timeout, _} ->
                    exit(ConnHandlerPid, normal),
                    {reply, {timeout, NextHop}, State};
                exit:{noproc, _} ->
                    exit(ConnHandlerPid, normal),
                    {reply, {noproc, NextHop}, State}
            end;
        false ->
            exit(ConnHandlerPid, normal),
            {reply, {no_band, {NextHop, Weight}}, State}
    end;
%% Request to communicate when MST is not computed from node's perspective
handle_call({request_to_communicate,  _} = Req, _From, State) when State#state.mst_state /= computed ->
    ?LOG_DEBUG("(~p) got (call) ~p but no info on MST", [State#state.name, Req]),
    {reply, {no_mst, State#state.name}, State};
handle_call({close_connection, To} = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Who = State#state.name,
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                           conn_handlers = maps:remove({Who, To},
                                               maps:remove({To, Who}, CurrentConnHandlers))},
    try
        exit(maps:get({State#state.name, To}, State#state.conn_handlers), normal),
        #edge{dst = NextHop} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
        gen_server:cast(NextHop, {close_connection, Who, To}),
        {reply, ok, NewState}
    catch
        error:_ -> {reply, ok, NewState} % the process already terminated for some reason
    end;
handle_call(leave = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Reason = normal,
    Reply = ok,
    {stop, Reason, Reply, State};
handle_call({send_data, From, To, Data}, _, State) ->
    case maps:find({From, To}, State#state.conn_handlers) of
        {ok, ConnHandlerPid} ->
            p2p_conn_handler:send_data(ConnHandlerPid, Data),
            {reply, ok, State};
        error ->
            {reply, {no_connection, {From, To}}, State}
    end;
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
handle_cast({close_connection, Who, To} = Req, State) when To /= State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                           conn_handlers = maps:remove({Who, To},
                                                       maps:remove({To, Who}, CurrentConnHandlers))},
    try
        exit(maps:get({Who, To}, State#state.conn_handlers), normal),
        #edge{dst = NextHop} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
        gen_server:cast(NextHop, {close_connection, Who, To}),
        {noreply, NewState}
    catch
        error:_ -> {noreply, NewState} % the process already terminated for some reason
    end;
handle_cast({close_connection, Who, To} = Req, State) when To == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
        CurrentConnections = State#state.connections,
        CurrentConnHandlers = State#state.conn_handlers,
        NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                               conn_handlers = maps:remove({Who, To},
                                                   maps:remove({To, Who}, CurrentConnHandlers))},
    try
        exit(maps:get({Who, To}, State#state.conn_handlers), normal),
        {noreply, NewState}
    catch
        error:_ -> {noreply, NewState} % the process already terminated for some reason
    end;
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
    dump_config(NewState),
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
            % io:format("unreachable ~p~n", [EdgeToDelete]);
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
    dump_config(NewState),
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
    Id = extract_id(State#state.name),
    file:delete(?CONFIG_DIR ++ "node_" ++ Id ++ ".json"),
    % dump_termination(Id),
    try
        exit(State#state.mst_computer_pid, kill),
        maps:foreach(fun(_ConnId, ConnHandler) -> exit(ConnHandler, kill) end, State#state.conn_handlers)
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

dump_termination(Id) ->
    FileName = ?CONFIG_DIR ++ "node_" ++ Id ++ ".json",
    {ok, Data} = file:read_file(FileName),
    Json = jsone:decode(Data),
    NewData = Json#{<<"state">> => <<"terminated">>},
    file:write_file(FileName, jsone:encode(NewData)).

dump_config(State) ->
    [_ , Id] = extract_id(State#state.name),
    Edges = lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                            [_, DstId] = extract_id(Dst),
                            [list_to_integer(DstId), Weight]
                      end, State#state.adjs),
    case State#state.mst_parent of
        #edge{dst = Parent, weight = Weight} ->
            [_, ParentId] = extract_id(Parent),
            ParentEdge = [[list_to_integer(ParentId), Weight]];
        none ->
            ParentEdge = []
    end,
    Mst = lists:uniq(
                    lists:map(fun({_Pid, #edge{dst = Dst, weight = Weight}}) ->
                                      [_, DstId] = extract_id(Dst),
                                      [list_to_integer(DstId), Weight]
                              end,
                              maps:to_list(State#state.mst_routing_table)
                             )
                    ++ ParentEdge
                   ),
    Json = jsone:encode(#{<<"id">> => list_to_bitstring(Id),
                          <<"edges">> => Edges,
                          <<"mst">> => Mst}),

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
                          exit:{timeout, _} -> {timed_out, Dst};
                          exit:{noproc, _} -> {noproc, Dst}
                      end
              end, Adjs).

get_connection_handler(SupRef) ->
    {ok, ConnHandler} = p2p_node_sup:start_connection_handler(SupRef),
    ConnHandler.

get_timeout() ->
    admin ! {self(), timer},
    receive
        {admin, Timeout} ->
            Timeout
    end.
