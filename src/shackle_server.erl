-module(shackle_server).
-include("shackle.hrl").

%% internal
-export([
    init/4,
    start_link/3
]).

%% sys behavior
-export([
    system_code_change/4,
    system_continue/3,
    system_terminate/4
]).

%% callbacks
-callback init() -> {ok, init_opts()}.
-callback after_connect(Socket :: inet:socket(), State :: term()) ->
    {ok, Socket :: inet:socket(), State :: term()}.

-callback handle_cast(Request :: term(), State :: term()) ->
    {ok, RequestId :: term(), Data :: binary(), State :: term()}.

-callback handle_data(Data :: binary(), State :: term()) ->
    {ok, [{RequestId :: term(), Reply :: term()}], State :: term()}.

-callback terminate(State :: term()) -> ok.

-record(state, {
    connect_retry = 1000      :: non_neg_integer(),
    child_name    = undefined :: atom(),
    ip            = undefined :: inet:ip_address() | inet:hostname(),
    module        = undefined :: module(),
    name          = undefined :: atom(),
    parent        = undefined :: pid(),
    port          = undefined :: inet:port_number(),
    reconnect     = true      :: boolean(),
    socket        = undefined :: undefined | inet:socket(),
    state         = undefined :: term(),
    timer         = undefined :: undefined | timer:ref()
}).

%% public
-spec start_link(atom(), atom(), module()) -> {ok, pid()}.

start_link(Name, ChildName, Module) ->
    proc_lib:start_link(?MODULE, init, [Name, ChildName, Module, self()]).

-spec init(atom(), atom(), module(), pid()) -> no_return().

init(Name, ChildName, Module, Parent) ->
    process_flag(trap_exit, true),
    proc_lib:init_ack(Parent, {ok, self()}),
    register(ChildName, self()),

    self() ! ?MSG_CONNECT,
    random:seed(os:timestamp()),
    shackle_backlog:new(ChildName),
    {ok, Opts} = Module:init(),

    loop(#state {
        child_name = ChildName,
        ip = ?LOOKUP(ip, Opts, ?DEFAULT_IP),
        module = Module,
        name = Name,
        parent = Parent,
        port = ?LOOKUP(port, Opts),
        reconnect = ?LOOKUP(reconnect, Opts, ?DEFAULT_RECONNECT),
        state = ?LOOKUP(state, Opts)
    }).

%% sys callbacks
-spec system_code_change(#state {}, module(), undefined | term(), term()) -> {ok, #state {}}.

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

-spec system_continue(pid(), [], #state {}) -> ok.

system_continue(_Parent, _Debug, State) ->
    loop(State).

-spec system_terminate(term(), pid(), [], #state {}) -> none().

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

%% private
connect_retry(#state {reconnect = false} = State) ->
    {ok, State#state {
        socket = undefined
    }};
connect_retry(#state {connect_retry = ConnectRetry} = State) ->
    ConnectRetry2 = shackle_backoff:timeout(ConnectRetry),

    {ok, State#state {
        connect_retry = ConnectRetry2,
        socket = undefined,
        timer = erlang:send_after(ConnectRetry2, self(), ?MSG_CONNECT)
    }}.

handle_msg(?MSG_CONNECT, #state {
        ip = Ip,
        port = Port
    } = State) ->

    Opts = [
        binary,
        {active, true},
        {packet, raw},
        {send_timeout, ?DEFAULT_SEND_TIMEOUT},
        {send_timeout_close, true}
    ],

    case gen_tcp:connect(Ip, Port, Opts) of
        {ok, Socket} ->
            {ok, State#state {
                socket = Socket,
                connect_retry = 0
            }};
        {error, Reason} ->
            shackle_utils:warning_msg("tcp connect error: ~p", [Reason]),
            connect_retry(State)
    end;
handle_msg({call, Ref, From, _Msg}, #state {
        socket = undefined,
        child_name = ChildName,
        name = Name
    } = State) ->

    reply(Name, ChildName, Ref, From, {error, no_socket}),
    {ok, State};
handle_msg({call, Ref, From, Request}, #state {
        child_name = ChildName,
        module = Module,
        socket = Socket,
        state = ClientState
    } = State) ->

    {ok, RequestId, Data, ClientState2} = Module:handle_cast(Request, ClientState),

    case gen_tcp:send(Socket, Data) of
        ok ->
            shackle_queue:in(ChildName, RequestId, {Ref, From}),

            {ok, State#state {
                state = ClientState2
            }};
        {error, Reason} ->
            shackle_utils:warning_msg("tcp send error: ~p", [Reason]),
            gen_tcp:close(Socket),
            tcp_close(State)
    end;
handle_msg({tcp, _Port, Data}, #state {
        child_name = ChildName,
        module = Module,
        name = Name,
        state = ClientState
    } = State) ->

    {ok, Replys, ClientState2} = Module:handle_data(Data, ClientState),

    lists:foreach(fun ({RequestId, Reply}) ->
        {Ref, From} = shackle_queue:out(ChildName, RequestId),
        reply(Name, ChildName, Ref, From, Reply)
    end, Replys),

    {ok, State#state {
        state = ClientState2
    }};
handle_msg({tcp_closed, Socket}, #state {
        socket = Socket
    } = State) ->

    shackle_utils:warning_msg("tcp closed", []),
    tcp_close(State);
handle_msg({tcp_error, Socket, Reason}, #state {
        socket = Socket
    } = State) ->

    shackle_utils:warning_msg("tcp error: ~p", [Reason]),
    gen_tcp:close(Socket),
    tcp_close(State).

loop(#state {parent = Parent} = State) ->
    receive
        {'EXIT', Parent, Reason} ->
            terminate(Reason, State);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
        Msg ->
            {ok, State2} = handle_msg(Msg, State),
            loop(State2)
    end.

reply(Name, ChildName, Ref, From, Msg) ->
    shackle_backlog:decrement(ChildName),
    From ! {Name, Ref, Msg}.

tcp_close(#state {child_name = ChildName, name = Name} = State) ->
    Msg = {error, tcp_closed},
    Items = shackle_queue:all(Name),
    [reply(Name, ChildName, Ref, From, Msg) || {Ref, From} <- Items],
    connect_retry(State).

terminate(Reason, _State) ->
    exit(Reason).
