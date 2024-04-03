%%%-------------------------------------------------------------------
%%% @author  <gianluca>
%%% @copyright (C) 2024,
%%% @doc
%%%
%%% @end
%%% Created: 24 March 2024
%%%-------------------------------------------------------------------
-module(p2p_node_sup).

-behaviour(supervisor).

%% API
-export([start_link/2, start_mst_worker/2, start_connection_handler/1]).

%% Supervisor callbacks
-export([init/1]).

% -define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================


start_mst_worker(SupRef, Name) ->
    Spec = #{id => 'mst_computer',
	       start => {ghs, start_link, [Name]},
	       restart => transient,
	       shutdown => 5000,
	       type => worker,
	       modules => [ghs]},
    supervisor:start_child(SupRef, Spec).


start_connection_handler(SupRef) ->
    {ok, ConnSup} = start_connection_handler_sup(SupRef),
    Spec = #{id => make_ref(),
	       start => {p2p_conn_handler, start_link, []},
	       restart => transient,
	       shutdown => 5000,
	       type => worker,
	       modules => [p2p_conn_handler]},
    supervisor:start_child(ConnSup, Spec).



%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name :: term(), Adjs :: term()) -> {ok, Pid :: pid()} |
	  {error, {already_started, Pid :: pid()}} |
	  {error, {shutdown, term()}} |
	  {error, term()} |
	  ignore.
start_link(Name, Adjs) ->
    supervisor:start_link(?MODULE, [Name, Adjs]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
	  {ok, {SupFlags :: supervisor:sup_flags(),
		[ChildSpec :: supervisor:child_spec()]}} |
	  ignore.
init([Name, Adjs]) ->
    SupFlags = #{strategy => one_for_one,
		 intensity => 1,
		 period => 5},


    Node = #{id => 'p2p_node',
	       start => {p2p_node, start_link, [[Name, Adjs, self()]]},
	       restart => transient,
	       shutdown => 5000,
	       type => worker,
	       modules => [p2p_node]},


    {ok, {SupFlags, [Node]}}.

%%%===================================================================
%%% Internal functions

start_connection_handler_sup(SupRef) ->
    SupSpec = #{id => 'p2p_conn_handler_sup',
	       start => {p2p_conn_handler_sup, start_link, []},
	       restart => transient,
	       shutdown => 5000,
	       type => supervisor,
	       modules => [p2p_conn_handler_sup]},
    % Try to start the connection handler supervisor
    case supervisor:start_child(SupRef, SupSpec) of
        {ok, ConnSup} ->
            {ok, ConnSup};
        {error, already_started, ConnSup} ->
            todo;
        _ ->
            ok % TODO: error management
    end.


%%===================================================================
