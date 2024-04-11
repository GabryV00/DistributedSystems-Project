%%%-------------------------------------------------------------------
%%% @author Gianluca Zavan
%%% @doc Implements the supervisor for the admin process and the TCP endpoint.
%%% @end
%%%-------------------------------------------------------------------
-module(p2p_admin_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================


%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link(Args :: term()) -> {ok, Pid :: pid()} |
	  {error, {already_started, Pid :: pid()}} |
	  {error, {shutdown, term()}} |
	  {error, term()} |
	  ignore.
start_link(Args) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Args).

start_link() -> start_link([]).

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
init(Args) ->

    case Args of
        [{port, Port} | _] when is_integer(Port), Port > 1024 -> ok;
        _ -> Port = 9000
    end,

    SupFlags = #{strategy => one_for_one,
		 intensity => 1,
		 period => 5},

    AdminNode =  #{id => make_ref(),
                   start => {'p2p_admin', start_link, [self()]},
                   restart => transient,
                   shutdown => 5000,
                   type => worker,
                   modules => ['p2p_admin']},

    TcpEndpoint =  #{id => make_ref(),
                     start => {'p2p_tcp', start_link, [[Port]]},
                     restart => permanent,
                     shutdown => 5000,
                     type => worker,
                     modules => ['p2p_tcp']},

    {ok, {SupFlags, [AdminNode, TcpEndpoint]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
