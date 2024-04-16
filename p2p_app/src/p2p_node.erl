%%%-------------------------------------------------------------------
%%% @author Gianluca Zavan
%%% @doc Implements the core peer logic.
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
        ?LOG_DEBUG("Node ~p started from file ~s", [Id, FileName]),
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
    try
        case gen_server:call(From, {request_to_communicate, {From, To, Band}}) of
            {timeout, _} = Reply ->
                start_mst_computation(From),
                Reply;
            {noproc, _} = Reply->
                start_mst_computation(From),
                Reply;
            Reply ->
                Reply
        end
    catch
        exit:{timeout, _Location} ->
            ?LOG_ERROR("Request to communicate to ~p timed out", [From]),
            {timeout, From};
        exit:{noproc, _Location} ->
            {noproc, From};
        exit:{shutdown, _Location} ->
            ?LOG_ERROR("The peer ~p was stopped during the call by its supervisor", [From]),
            {shutdown, From}
    end.

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
        true = validate_edges(Ref, Adjs),
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
    ?LOG_INFO("joining the network", #{process_name => Name}),
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
    % Add the PID of the MST computer to the MST neighbor list
    case lists:keyfind(MstPid, 2, MstAdjs) of
         false ->
            NewMstAdjs = [#edge{src = MstComputer, dst = MstPid, weight = Weight} | MstAdjs];
         _ ->
            NewMstAdjs = MstAdjs
    end,

    % Add the name of the peer to the neighbor list
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
    % Start the echo wave to inform other peers of new MST computation
    {ok, Unreachable} = echo_node_behaviour(Name, Adjs, Adjs, Name, SessionID),
    % Update the neighbor list by removing who didn't answer during the echo wave
    MergedAdjs = lists:zip(Adjs, MstAdjs),
    NewAdjs = Adjs -- Unreachable,
    {_, NewMstAdjs} = lists:unzip(filter_out(NewAdjs, MergedAdjs)),
    ?LOG_DEBUG("(~p) echo wave successful, starting MST", [Name]),
    % Start the actual MST computation now that everyone else knows about it
    start_mst_computation(Name, NewAdjs, NewMstAdjs, MstComputer, SessionID),
    NewState = State#state{adjs = NewAdjs,
                           mst_adjs = NewMstAdjs,
                           current_mst_session = SessionID,
                           mst_state = computing},
    {reply, ok, NewState};
%% Request to communicate from source node perspective when MST has been computed
handle_call({request_to_communicate, {Who, To, Band}} = Req, _From, State) when State#state.mst_state == computed andalso Who == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    % Get a fresh connection handler
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    % Check if there is a way to route the request to communicate
    case maps:get(To, State#state.mst_routing_table, State#state.mst_parent) of
        #edge{dst = NextHop, weight = Weight} -> ok;
        none -> Weight = 0, NextHop = none
    end,
    % Try to establish a connection along the path on the MST towards `To'
    Outcome = establish_connection(Who, To, Band, {none, NextHop}, Weight, ConnHandlerPid),
    case Outcome of
        % The connection has been established
        {ok, _} ->
            CurrentConnections = State#state.connections,
            CurrentConnHandlers = State#state.conn_handlers,
            NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                   % Use the connection handler to send and receive messages
                                   conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
            {reply, {ok, ConnHandlerPid}, NewState};
        % Something went wrong on the path towards `To'
        _ ->
            {reply, Outcome, State}
    end;
%% Request to communicate from destination node perspective
handle_call({request_to_communicate, {Who, To, _Band, LastHop}} = Req, _From, State) when State#state.mst_state == computed andalso To == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    % Get a fresh connection handler
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    % Tell the connection handler where to forward data, and where it's coming from
    p2p_conn_handler:talk_to(ConnHandlerPid, LastHop, Who, To),
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = [{Who, To} | CurrentConnections],
                           % Use the connection handler to send and receive messages
                           conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
    {reply, {ok, ConnHandlerPid}, NewState};
%% Request to communicate from intermediate node perspective
handle_call({request_to_communicate, {Who, To, Band, LastHop}} = Req, _From, State) when State#state.mst_state == computed andalso To /= State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    % Get a fresh connection handler
    ConnHandlerPid = get_connection_handler(State#state.supervisor),
    % Check if there is a way to route the request to communicate
    case maps:get(To, State#state.mst_routing_table, State#state.mst_parent) of
        #edge{dst = NextHop, weight = Weight} -> ok;
        none -> Weight = 0, NextHop = none
    end,
    % Forward the request to communicate message along the path towards `To'
    Outcome = establish_connection(Who, To, Band, {LastHop, NextHop}, Weight, ConnHandlerPid),
    case Outcome of
        {ok, _} ->
                CurrentConnections = State#state.connections,
                CurrentConnHandlers = State#state.conn_handlers,
                NewState = State#state{connections = [{Who, To} | CurrentConnections],
                                       conn_handlers = CurrentConnHandlers#{{Who, To} => ConnHandlerPid, {To, Who} => ConnHandlerPid}},
                {reply, {ok, ConnHandlerPid}, NewState};
        _ ->
            {reply, Outcome, State}
    end;
%% Request to communicate when MST is not computed from node's perspective
handle_call({request_to_communicate,  _} = Req, _From, State) when State#state.mst_state /= computed ->
    ?LOG_DEBUG("(~p) got (call) ~p but no info on MST", [State#state.name, Req]),
    {reply, {no_mst, State#state.name}, State};
%% Peer has to close the connection towards `To'
handle_call({close_connection, To} = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Who = State#state.name,
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    % Remove the connection handler references
    NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                           conn_handlers = maps:remove({Who, To},
                                               maps:remove({To, Who}, CurrentConnHandlers))},
    try
        % Kill the specific connection handler
        exit(maps:get({State#state.name, To}, State#state.conn_handlers), normal),
        #edge{dst = NextHop} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
        % Send an asynchronous request to the next hop
        gen_server:cast(NextHop, {close_connection, Who, To}),
        {reply, ok, NewState}
    catch
        error:_ -> {reply, ok, NewState} % the process already terminated for some reason
    end;
%% Peer leaves the network
handle_call(leave = Req, _From, State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Reason = normal,
    Reply = ok,
    {stop, Reason, Reply, State};
%% Peer wants to send data to peer `To'
handle_call({send_data, From, To, Data}, _, State) ->
    % Check if there exist an open connection with `To'
    case maps:find({From, To}, State#state.conn_handlers) of
        {ok, ConnHandlerPid} ->
            % Use the specific connecion handler
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
%% A peer along the path to `To' decided to close the connection and sent an async request
handle_cast({close_connection, Who, To} = Req, State) when To /= State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    CurrentConnections = State#state.connections,
    CurrentConnHandlers = State#state.conn_handlers,
    NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                           conn_handlers = maps:remove({Who, To},
                                                       maps:remove({To, Who}, CurrentConnHandlers))},
    try
        % Kill the specific connection handler
        exit(maps:get({Who, To}, State#state.conn_handlers), normal),
        #edge{dst = NextHop} = maps:get(To, State#state.mst_routing_table, State#state.mst_parent),
        % Forward the request
        gen_server:cast(NextHop, {close_connection, Who, To}),
        {noreply, NewState}
    catch
        error:_ -> {noreply, NewState} % the process already terminated for some reason
    end;
%% The request arrived to destination
handle_cast({close_connection, Who, To} = Req, State) when To == State#state.name ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
        CurrentConnections = State#state.connections,
        CurrentConnHandlers = State#state.conn_handlers,
        NewState = State#state{connections = CurrentConnections -- [{Who, To}],
                               conn_handlers = maps:remove({Who, To},
                                                   maps:remove({To, Who}, CurrentConnHandlers))},
    try
        % Kill the specific connection handler
        exit(maps:get({Who, To}, State#state.conn_handlers), normal),
        {noreply, NewState}
    catch
        error:_ -> {noreply, NewState} % the process already terminated for some reason
    end;
handle_cast(Request, State) ->
    ?LOG_DEBUG("(~p) got (cast) ~p, not managed", [State#state.name, Request]),
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
%% The MST computer finished its task in the algorithm and reports its MST edges
handle_info({done, {SessionID, MstParent, MstRoutingTable}} = Msg, State) when SessionID >= State#state.current_mst_session ->
    ?LOG_DEBUG("(~p) got ~p from my MST computer", [State#state.name, Msg]),
    ?LOG_INFO("MST computation (session ~p) terminated", [SessionID], #{process_name => State#state.name}),
    % Update the peer's state because now the MST has been computed
    NewState = State#state{current_mst_session = SessionID,
                           mst_state = computed,
                           mst_parent = MstParent,
                           mst_routing_table = MstRoutingTable},
    % Change the configuration file
    dump_config(NewState),
    {noreply, NewState};
%% The MST computer detected an unreachable peer
handle_info({unreachable, SessionID, Who} = Msg, State) when SessionID >= State#state.current_mst_session ->
    ?LOG_DEBUG("(~p) got ~p from my MST computer", [State#state.name, Msg]),
    MstAdjs = State#state.mst_adjs,
    Adjs = State#state.adjs,
    MstEdgeToDelete = lists:keyfind(Who, 2, MstAdjs),

    % Delete the appropriate edge towards the unreachable peer
    case lists:keyfind(MstEdgeToDelete, 1, lists:zip(MstAdjs, Adjs)) of
        {_, #edge{dst = Dst} = EdgeToDelete} ->
            ?LOG_INFO("~p became unreachable while computing MST", [Dst], #{process_name => State#state.name}),
            NewAdjs = lists:delete(EdgeToDelete, Adjs),
            NewMstAdjs = lists:delete(MstEdgeToDelete, MstAdjs);
            % io:format("unreachable ~p~n", [EdgeToDelete]);
        false ->
            NewAdjs = Adjs,
            NewMstAdjs = MstAdjs
    end,


    % Get a fresh session ID to start a new MST computation
    NewSessionID = get_new_session_id(),
    Name = State#state.name,
    % Start a new echo wave to inform other peers
    echo_node_behaviour(Name, NewAdjs, NewAdjs, Name, NewSessionID),
    % Start a new MST computation with the new neighbor list
    start_mst_computation(State#state.name, NewAdjs, NewMstAdjs, State#state.mst_computer_pid, NewSessionID),
    NewState = State#state{adjs = NewAdjs,
                           mst_adjs = NewMstAdjs,
                           current_mst_session = NewSessionID,
                           mst_state = computing},
    dump_config(NewState),
    {noreply, NewState};
%% Received by a peer when another one started an echo wave
handle_info({awake, NameFrom, SessionID}, #state{current_mst_session = CurrentMstSession} = State) when SessionID > CurrentMstSession ->
    Name = State#state.name,
    ?LOG_DEBUG("(~p) Received token from ~p", [Name, NameFrom]),
    Adjs = State#state.adjs,
    % Filter out the peer who sent the awake message
    ToAwake = lists:filter(fun(#edge{dst = Dst}) ->
                                   Dst =/= NameFrom
                           end , Adjs),
    MstAdjs = State#state.mst_adjs,
    MstComputer = State#state.mst_computer_pid,
    % Participate in the echo wave
    {ok, Unreachable} = echo_node_behaviour(Name, ToAwake, ToAwake, NameFrom, SessionID),
    % Filter out the peers who didn't answer during the echo wave
    MergedAdjs = lists:zip(Adjs, MstAdjs),
    NewAdjs = Adjs -- Unreachable,
    {_, NewMstAdjs} = lists:unzip(filter_out(NewAdjs, MergedAdjs)),
    ?LOG_DEBUG("(~p) echo wave successful, starting MST", [Name]),
    % Start the MST computation
    start_mst_computation(Name, NewAdjs, NewMstAdjs, MstComputer, SessionID),
    {noreply, State#state{adjs = NewAdjs, mst_adjs = NewMstAdjs, current_mst_session = SessionID, mst_state = computing}};
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
    % Delete the peer's config file
    file:delete(?CONFIG_DIR ++ "node_" ++ Id ++ ".json"),
    ?LOG_INFO("terminating", #{process_name => State#state.name}),
    try
        exit(State#state.mst_computer_pid, kill),
        maps:foreach(fun(_ConnId, ConnHandler) -> exit(ConnHandler, kill) end, State#state.conn_handlers)
    catch
        error:_ -> ok % Mst process is already dead for some reason, it's ok
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
    ?LOG_INFO("starting MST computation with SessionID=~p and adjs=~p", [SessionID, Adjs], #{process_name => Name}),
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


%% @private
%% @doc Change the JSON config file based on peer's state.
%% @param State The raw state of the peer
%% @end
dump_config(State) ->
    % Get the peer's numerical ID
    [_ , Id] = extract_id(State#state.name),
    % Transform the peer's edges in the appropriate format, which is [[NeighborID :: integer(), Weight :: integer()]]
    Edges = lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                            [_, DstId] = extract_id(Dst),
                            [list_to_integer(DstId), Weight]
                      end, State#state.adjs),
    % Check if there is a (unique) edge that is part of the MST sink tree
    case State#state.mst_parent of
        #edge{dst = Parent, weight = Weight} ->
            [_, ParentId] = extract_id(Parent),
            ParentEdge = [[list_to_integer(ParentId), Weight]];
        none ->
            ParentEdge = []
    end,
    % Get all the unique edges that are part of the MST
    Mst = lists:uniq(
                    lists:map(fun({_Pid, #edge{dst = Dst, weight = Weight}}) ->
                                      [_, DstId] = extract_id(Dst),
                                      [list_to_integer(DstId), Weight]
                              end,
                              maps:to_list(State#state.mst_routing_table)
                             )
                    % Include the parent edge previously extracted
                    ++ ParentEdge
                   ),
    % Encode everyting in JSON
    Json = jsone:encode(#{<<"id">> => list_to_bitstring(Id),
                          <<"edges">> => Edges,
                          <<"mst">> => Mst}),
    % Save the file
    file:write_file(?CONFIG_DIR ++ "node_" ++ Id ++ ".json", Json).


%% @private
%% @doc Extract the numerical ID of the peer from it's name (kinda wonky).
%% @param Name The name of the peer (atom)
%% @end
extract_id(Name) ->
    string:split(atom_to_list(Name), "node").


%% @private
%% @doc Check that all the edges have `Name' as source, have a non-negative weight and don't cause self-loops.
%% @param Name The name of the peer
%% @param Edges List of #edge records
%% @return `true' if all the edges pass the checks, `false' otherwise
%% @throws edges_not_valid
%% @end
validate_edges(Name, Edges) ->
    try
        lists:all(fun(#edge{src = Src, dst = Dst, weight = Weight}) ->
                      (is_atom(Src) or is_pid(Src)) andalso
                      (is_atom(Dst) or is_pid(Dst)) andalso
                      is_number(Weight) andalso Weight > 0 andalso
                      Src == Name andalso Dst /= Name
                  end , Edges)
    catch
        _ -> throw(edges_not_valid)
    end.

%% @private
%% @doc Send the appropriate requests to the peers in `Adjs' to get their MST computer pid.
%% @param Adjs List of #edge records
%% @param Name The peer's name
%% @param MstComputer The pid of the MstComputer of `Name'
%% @return A list of tuples, each of which can be: `{ok, #edge{src=MstComputer,
%%  dst=NeighborMstPid, weight=Weight}}' if the neighbor answered with its MST
%%  computer pid, `{timeout, Dst}' if neighbor `Dst' didn't answer in the given
%%  time frame and `{noproc, Dst}' if `Dst' is dead
%% @end
get_neighbors_mst_pid(Adjs, Name, MstComputer) ->
    ?LOG_INFO("Announicing presence to neighbors", #{process_name => Name}),
    lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                      try
                          DstPid = gen_server:call(Dst, {new_neighbor, Name, Weight, MstComputer}),
                          {ok, #edge{src = MstComputer, dst = DstPid, weight = Weight}}
                      catch
                          exit:{timeout, _} -> {timed_out, Dst};
                          exit:{noproc, _} -> {noproc, Dst}
                      end
              end, Adjs).

%% @private
%% @doc Asks the peer's supervisor to spawn and supervise a new connection handler process
%% @param SupRef The pid of the supervisor
%% @returns The pid of the connection handler
%% @end
get_connection_handler(SupRef) ->
    {ok, ConnHandler} = p2p_node_sup:start_connection_handler(SupRef),
    ConnHandler.

%% @private
%% @doc Asks to the admin for an appropriate timeout value in milliseconds based on the number of peers in the network.
%% @return The number of milliseconds to use as timeout
%% @end
get_timeout() ->
    admin ! {self(), timer},
    receive
        {admin, Timeout} ->
            Timeout
    end.



%% @private
%% @doc Takes the tuples in L2 such that the first element is in L1.
%% The lists should be sorted. If A appears before than B in L1 and {A,_}
%% is in L2 and {B,_} is in L2, then {A,_} should appear before {B,_}.
%% @param L1 Arbitrary list
%% @param L2 Proplist
%% @end
-spec filter_out(L1 :: list(), L2 :: [{term(), term()}]) -> [{term(), term()}].
filter_out(L1, L2) ->
    lists:reverse(filter_out(L1, L2, [])).
filter_out([], _, Res) ->
    Res;
filter_out(_, [], Res) ->
    Res;
filter_out([H | T1], [{H, _} = E | T2], Res) ->
    filter_out(T1, T2, [E | Res]);
filter_out([H1 | _] = L1, [{H2, _} | T2], Res) when H1 /= H2 ->
    filter_out(L1, T2, Res).


%% @private
%% @doc Implements the operations to perfom during a echo wave
%% @param Name Is the name of the peer participating in the wave
%% @param AdjsOut Is the list of edges towards the children peers
%% @param AdjsIn Is the list of the edges from which the peer expects to receive the token back
%% @param Parent Is the Name of the peer from which the echo request came from
%% @param SessionID Is the ID of the MST session that caused the echo wave
%% @end
echo_node_behaviour(Name, AdjsOut, AdjsIn, Parent, SessionID) ->
    Timeout = get_timeout(),
    echo_node_behaviour(Name, AdjsOut, AdjsIn, Parent, SessionID, Timeout, []).
echo_node_behaviour(Name, AdjsOut, AdjsIn, Parent, SessionID, Timeout, Unreachable) ->
    if
        AdjsOut /= [] ->       % first phase: send token out to all adjacent nodes (except parent)
            Outcomes = lists:map(fun (#edge{dst = P} = Edge) ->
                                         try
                                             % ?LOG_DEBUG("(~p) awakening ~p~n", [Name, P]),
                                             P ! {awake, Name, SessionID},
                                             {ok, Edge}
                                         catch
                                             error:_ -> {unreachable, Edge}
                                         end
                                 end, AdjsOut),
            NewUnreachable = proplists:get_all_values(unreachable, Outcomes),
            % ?LOG_DEBUG("(~p) Unreachable nodes ~p", [Name, NewUnreachable]),
            NewAdjsIn = AdjsIn -- NewUnreachable,
            echo_node_behaviour(Name, [], NewAdjsIn, Parent, SessionID, Timeout, NewUnreachable);

        AdjsIn /= [] ->        % second phase: wait for token back from adjacent nodes
            receive
                {awake, Child, SessionID} ->
                    % ?LOG_DEBUG("(~p) received token from child ~p~n", [Name, Child]),
                    EdgeToDelete = lists:keyfind(Child, 2, AdjsIn),
                    NewAdjsIn = lists:delete(EdgeToDelete, AdjsIn),
                    echo_node_behaviour(Name, [], NewAdjsIn, Parent, SessionID, Timeout, Unreachable)
            after Timeout ->
                  {ok, Unreachable ++ AdjsIn}
            end;

        true ->                % last phase: report back to parent
            case Parent == Name of
                true ->
                    % ?LOG_DEBUG("(~p) Echo wave terminated", [Name]),
                    {ok, Unreachable};
                false ->
                    % ?LOG_DEBUG("(~p) sending back to parent ~p~n", [Name, Parent]),
                    Parent ! {awake, Name, SessionID},
                    {ok, Unreachable}
            end
    end.


%% @private
%% @doc Perform the needed operations to send the request to communicate along the path on the MST
%% @param Who The source of the communication request (could be another peer)
%% @param To The destination of the communication request
%% @param Band The bandwidth requested for the communication
%% @param {LastHop, NextHop} LastHop is the connection handler pid to contact
%%  to forward the data towards `Who', and can be `none' in case the function
%%  is called by the source peer. `NextHop' is the connection handler pid to
%%  contact to forward the data towards 'To`, and can be none in case there is
%%  no route to reach `To'.
%% @param Weight Is the weight of the edge connecting the peer to the next one on the path
%% @param ConnHandlerPid Is the connection handler pid of the peer calling the function
%% @return `{no_route, To}' if there is no way to reach `To' (could be because of network partitioning)
%%   `{no_band, To}' if an edge on the path towards `To' has a weight strictly less than `Band', so the request is unsatisfiable
%%   `{timeout, Name}' if `Name' on the path didn't send back its connection handler pid in time
%%   `{noproc, Name}' if `Name' on the path is dead
%% @end
establish_connection(_Who, To, _Band, {_, none}, _Weight, ConnHandlerPid) ->
    exit(ConnHandlerPid, normal),
    {no_route, To};
establish_connection(_, _, Band, {_, NextHop}, Weight, ConnHandlerPid) when Weight < Band ->
    exit(ConnHandlerPid, normal),
    {no_band, {NextHop, Weight}};
establish_connection(Who, To, Band, {LastHop, NextHop}, Weight, ConnHandlerPid) when Weight >= Band andalso NextHop /= none ->
    try
        Timeout = get_timeout(),
        case gen_server:call(NextHop, {request_to_communicate, {Who, To, Band, ConnHandlerPid}}, Timeout) of
            {ok, NextHopConnHandler} ->
                case LastHop of
                    none ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, Who, To),
                        {ok, ConnHandlerPid};
                    _ ->
                        p2p_conn_handler:talk_to(ConnHandlerPid, NextHopConnHandler, LastHop, Who, To),
                        {ok, ConnHandlerPid}
                end;
            Reply ->
                exit(ConnHandlerPid, normal),
                Reply
        end
    catch
        exit:{timeout, _} ->
            exit(ConnHandlerPid, normal),
            {timeout, NextHop};
        exit:{noproc, _} ->
            exit(ConnHandlerPid, normal),
            {noproc, NextHop}
    end.
