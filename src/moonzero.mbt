// The surface moonzero had before it was split into packages, re-exported from
// where each name now lives, so `@moonzero.Breaker` and the rest keep working.

///|
pub using @clock {type Clock, type ManualClock}

///|
pub using @proc {type ShutdownCoordinator}

///|
pub using @logx {
  type Logger,
  type LogLevel,
  duration_key,
  entry,
  level_name,
  logx,
  message_key,
  set_log_level,
  set_log_sink,
  set_log_writer,
  stamp_key,
}

///|
pub using @trace {
  type TraceContext,
  generate_span_id,
  generate_trace_id,
  next_trace_context,
  parse_traceparent,
}

///|
pub using @metric {
  type CounterVec,
  type Histogram,
  type ServerMetrics,
  default_latency_buckets,
  exposition_content_type,
}

///|
pub using @breaker {type Breaker, type Promise, type Unavailable}

///|
pub using @shedder {type Shedder, type Ticket}

///|
pub using @conf {
  type Conf,
  type ConfigError,
  type MiddlewaresConf,
  type PrivateKeyConf,
  type RestConf,
  type RpcServerConf,
  type ServiceConf,
  type SignatureConf,
  canonical_key,
  port,
  rpc_port,
}

///|
pub using @zrpc {
  type BidiCall,
  type BidiStreamFactory,
  type BidiStreamHandler,
  type ClientStreamHandler,
  type RpcChannel,
  type RpcGroup,
  type RpcHandler,
  type RpcServer,
  type ServerStreamHandler,
  status_of_code,
}

///|
pub using @balance {
  type Balancer,
  type LoadBalancedChannel,
  type Resolve,
  type RpcCluster,
}

///|
pub using @moonsd {
  trait Discovery,
  trait Registrar,
  trait Watcher,
  type Endpoint,
  type Lease,
  type Update,
  type View,
  hold,
}

///|
pub using @limit {
  type MaxConns,
  type PeriodLimit,
  type PeriodResult,
  type RedisPeriodLimit,
  type RedisTokenLimit,
  type TokenBucket,
  period_script,
  token_script,
}

///|
pub using @handler {
  type CorsConf,
  type Middleware,
  type Refusal,
  type RequestLog,
  auth,
  breaker,
  cors,
  jwt_authorized,
  jwt_sign,
  jwt_verify,
  logging,
  max_conns,
  maxbytes,
  metrics,
  metrics_handler,
  mount_metrics,
  period_limit,
  plain_text,
  rate_limit,
  recovery,
  redis_period_limit,
  redis_rate_limit,
  refusal,
  request_id,
  shedding,
  structured_logging,
  timed_out,
  timeout,
  too_large,
  too_many,
  tracing,
  unavailable,
}

///|
pub using @rest {type Group, type Layer, type RestEngine, type Server}
