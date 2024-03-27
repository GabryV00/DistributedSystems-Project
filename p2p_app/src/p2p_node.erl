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
         request_to_communicate/3, leave_network/1]).

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

request_to_communicate(Pid, To, Band) ->
    gen_server:call(Pid, {request_to_communicate, To, Band}, 10000).

% start_stream(To) ->
%     gen_server:call(self(), {start_stream, To}).

% end_stream(To) ->
%     gen_server:call(self(), {end_stream, To}).

% send_data(To) ->
%     todo.

leave_network(Pid) ->
    todo.

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
    State = #state{
          name = Name,
          adjs = Adjs,
          mst_adjs = [],
          supervisor = Supervisor,
          current_mst_session = 0
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
handle_call(get_state, _, State) ->
    {reply, State, State};
handle_call({join, Adjs}, _From, #state{name = Name, supervisor = Supervisor, mst_computer_pid = MstComputerPid} = State) ->
    MstComputer = get_mst_worker(Name, MstComputerPid, Supervisor),
    MstAdjs = lists:map(fun(#edge{dst = Dst, weight = Weight}) ->
                      DstPid = gen_server:call(Dst, {new_neighbor, Name, Weight, MstComputer}),
                      #edge{src = MstComputer, dst = DstPid, weight = Weight}
              end, Adjs),
    NewAdjs = Adjs,
    SessionID = get_new_session_id(),
    start_mst_computation(Name, NewAdjs, MstAdjs, MstComputer, SessionID),
    NewState = State#state{
                 adjs = NewAdjs,
                 mst_computer_pid = MstComputer,
                 mst_adjs = MstAdjs,
                 current_mst_session = SessionID},
    {reply, ok, NewState};
% A new neighbor appeared and asks to join the network
handle_call({new_neighbor, NeighborName, Weight, MstPid}, _NodeFrom,
            #state{name = Name, adjs = Adjs, mst_computer_pid = Pid, mst_adjs = MstAdjs} = State) ->
    Supervisor = State#state.supervisor,
    MstComputer = get_mst_worker(Name, Pid, Supervisor),
    % delete old edges to NeighborName if they already exist
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
    {reply, MstComputer, NewState};
handle_call({request_to_communicate, To, Band}, _From, #state{mst_computer_pid = MstComputer} = State) ->
    MstInfo = get_mst_info(MstComputer),
    {reply, MstInfo, State};
handle_call(_Request, _From, State) ->
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
% when this message is received, someone (maybe the same node) wants to start
% computing the mst
handle_cast({awake, NameFrom, SessionID}, #state{current_mst_session = CurrentMstSession} = State) when SessionID > CurrentMstSession ->
    Name = State#state.name,
    Adjs = State#state.adjs,
    MstComputer = State#state.mst_computer_pid,
    MstAdjs = State#state.mst_adjs,
    ToAwake = lists:filter(fun(#edge{dst = Dst}) ->
                                   Dst =/= NameFrom
                           end , Adjs),
    start_mst_computation(Name, ToAwake, MstAdjs, MstComputer, SessionID),
    {noreply, State#state{current_mst_session = SessionID}};
handle_cast(_Request, State) ->
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
terminate(_Reason, _State) ->
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

start_mst_computation(Name, Adjs, MstAdjs, MstComputerPid, SessionID) ->
    lists:foreach(fun(#edge{dst = Dst}) ->
                          ?LOG_DEBUG("~p awakening node ~p", [Name, Dst]),
                          gen_server:cast(Dst, {awake, Name, SessionID})
                  end,
                  Adjs),
    MstComputerPid ! {SessionID, {change_adjs, MstAdjs}}.



get_mst_worker(Name, Current, Supervisor) ->
    case Current of
        undefined ->
            {ok, New} = p2p_node_sup:start_mst_worker(Supervisor, Name),
            New;
        _Pid ->
            Current
    end.

get_new_session_id() ->
    admin ! {self(), new_id},
    receive
        {admin, Id} ->
        Id
    end.

get_mst_info(MstComputer) ->
    MstComputer ! {info, {self(), get_state}},
    receive
        {MstComputer, Info} ->
            Info
    end.
