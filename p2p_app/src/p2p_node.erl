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
         request_to_communicate/3, leave_network/1, close_connection/2, init_node_from_file/1]).

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
          conn_supervisor :: pid(),
          current_mst_session :: term(),
          connections = [] :: list(),
          mst_computer_pid :: pid()
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
        p2p_node_sup:start_link(Id, Edges)
    catch
        error:{Reason, _Stack} ->
            ?LOG_ERROR("Error: ~p during init on file ~p", [Reason, FileName])
    end.

request_to_communicate(From, To, Band) ->
    gen_server:call(From, {request_to_communicate, To, Band}, 10000).

close_connection(From, To) ->
    gen_server:call(From, {close_connection, To}).

% start_stream(To) ->
%     gen_server:call(self(), {start_stream, To}).

% end_stream(To) ->
%     gen_server:call(self(), {end_stream, To}).

% send_data(To) ->
%     todo.


leave_network(Pid) ->
    gen_server:call(Pid, leave).

join_network(Pid, Adjs) ->
    gen_server:call(Pid, {join, Adjs}, infinity).

get_state(Pid) ->
    gen_server:call(Pid, get_state).



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
          current_mst_session = 0
         },

    dump_config(State),
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
    MstAdjs = lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                      DstPid = gen_server:call(Dst, {new_neighbor, Name, Weight, MstComputer}),
                      #edge{src = MstComputer, dst = DstPid, weight = Weight}
              end, Adjs),
    % Update the neighbor list
    NewAdjs = Adjs,
    % Get a new MST session ID from the Admin, this will be used to compute the MST
    SessionID = get_new_session_id(),
    % Notify neighbors and start to compute the MST
    start_mst_computation(Name, NewAdjs, MstAdjs, MstComputer, SessionID),
    NewState = State#state{
                 adjs = NewAdjs,
                 mst_computer_pid = MstComputer,
                 mst_adjs = MstAdjs,
                 current_mst_session = SessionID},
    {reply, ok, NewState};
%% A new neighbor appeared and asks to join the network
handle_call({new_neighbor, NeighborName, Weight, MstPid} = Req, _NodeFrom,
            #state{name = Name, adjs = Adjs, mst_computer_pid = Pid, mst_adjs = MstAdjs} = State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    Supervisor = State#state.supervisor,
    % Get a process to compute the MST, if it doesn't already exist
    MstComputer = get_mst_worker(Name, Pid, Supervisor),
    % Delete old edges to NeighborName if they already exist
    MstAdjsWithoutNeighbor = lists:filter(fun(#edge{dst = Dst}) ->
                                                  Dst =/= MstPid
                                          end, MstAdjs),
    AdjsWithoutNeighbor = lists:filter(fun(#edge{dst = Dst}) ->
                                                  Dst =/= NeighborName
                                          end, Adjs),
    NewState = State#state{
                 mst_adjs = [#edge{src = MstComputer, dst = MstPid, weight = Weight} | MstAdjsWithoutNeighbor],
                 adjs = [#edge{src = Name, dst = NeighborName, weight = Weight} | AdjsWithoutNeighbor],
                 mst_computer_pid = MstComputer
                },
    % Reply to the neighbor with the pid of the MST process
    {reply, MstComputer, NewState};
%% Request to communicate with node To, using Band
handle_call({request_to_communicate, To, Band} = Req, _From, #state{mst_computer_pid = MstComputer} = State) ->
    ?LOG_DEBUG("(~p) got (call) ~p", [State#state.name, Req]),
    MstInfo = get_mst_info(MstComputer),
    {reply, MstInfo, State};
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
    {noreply, State#state{current_mst_session = SessionID}};
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
handle_info({done, _SessionID} = Msg, State) ->
    ?LOG_DEBUG("(~p) got ~p from my MST computer", [Msg]),
    {noreply, State};
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
get_new_session_id() ->
    admin ! {self(), new_id},
    receive
        {admin, Id} ->
        Id
    end.

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
