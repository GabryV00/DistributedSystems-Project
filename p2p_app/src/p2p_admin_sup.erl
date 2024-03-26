%%%-------------------------------------------------------------------
%%% @author  <gianluca>
%%% @copyright (C) 2024, 
%%% @doc
%%%
%%% @end
%%% Created: 25 March 2024
%%%-------------------------------------------------------------------
-module(p2p_admin_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, spawn_node/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================


spawn_node(Supervisor, Name, Adjs) ->
    NodeSupSpec = #{id => make_ref(),
                    start => {'p2p_sup', start_link, [Name, Adjs]},
                    restart => permanent,
                    shutdown => 5000,
                    type => supervisor,
                    modules => ['p2p_sup']},
    supervisor:start_child(Supervisor, NodeSupSpec).

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

    AdminNode =  #{id => make_ref(),
                   start => {'p2p_admin', start_link, [self()]},
                   restart => transient,
                   shutdown => 5000,
                   type => worker,
                   modules => ['p2p_admin']},
    {ok, {SupFlags, [AdminNode]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
