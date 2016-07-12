%% defaults
-define(DEFAULT_BACKLOG_SIZE, 1024).
-define(DEFAULT_IP, "127.0.0.1").
-define(DEFAULT_POOL_SIZE, 16).
-define(DEFAULT_POOL_STRATEGY, round_robin).
-define(DEFAULT_PROTOCOL, shackle_tcp).
-define(DEFAULT_RECONNECT, true).
-define(DEFAULT_RECONNECT_MAX, timer:minutes(2)).
-define(DEFAULT_RECONNECT_MIN, 10).
-define(DEFAULT_SOCKET_OPTS, []).
-define(DEFAULT_TIMEOUT, 1000).
