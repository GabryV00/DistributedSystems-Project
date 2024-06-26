%%%-------------------------------------------------------------------
%%% @author Gianluca Zavan
%%% @doc Implements the supervisor for all the peers in the network.
%%% @end
%%% Created: 28 March 2024
%%%-------------------------------------------------------------------
-module(p2p_node_manager).

-behaviour(supervisor).
-include("records.hrl").

%% API
-export([start_link/0, spawn_node/2]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, p2p_node_manager).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Adds a child process for a new peer in the supervisor list.
%% @param Name The name of the new peer
%% @param Adjs The list of incident edges of the peer
%% @end
-spec spawn_node(Name :: pid(), Adjs :: [#edge{}]) -> {ok, Child :: pid()}.
spawn_node(Name, Adjs) ->
    NodeSupSpec = #{id => make_ref(),
                    start => {'p2p_node_sup', start_link, [Name, Adjs]},
                    restart => permanent,
                    shutdown => 5000,
                    type => supervisor,
                    modules => ['p2p_node_sup']},
    supervisor:start_child(p2p_node_manager, NodeSupSpec).

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
	  {error, {already_started, Pid :: pid()}} |
	  {error, {shutdown, term()}} |
	  {error, term()} |
	  ignore.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

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
init([]) ->

    SupFlags = #{strategy => one_for_one,
		 intensity => 1,
		 period => 5},

    {ok, {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
