-module(erl_counter_mnesia).

-record(mapper, {name, value}).
-record(daily_counter, {name, value}).
-record(counter, {name, value}).
-record(timeout_counter, {name, timeout, value}).

-export([start/0,
		get/1,
		set/2,
		del/1,
		get_timeout/1,
		set_timeout/3,
		del_timeout/1,
		get_incr/1,
		incr/2,
		del_incr/1,
		incr_daily_counter/2,
		get_daily_counter/1,
		del_daily_counter/1,
		clean_daily_counters/0,
		clear_timeout_counter/0]).

start() ->
	%% error_logger:info_msg("erl_counter_begin"),
	mnesia:create_schema([node()]),
    mnesia:start(),
    %% forever memory
	mnesia:create_table(mapper, [{disc_copies, [node()]},
                                 {type, set},
                                 {attributes, record_info(fields, mapper)}]),
	%% forever counter
    mnesia:create_table(counter, [{disc_copies, [node()]},
                                  {type, set},
                                  {attributes, record_info(fields, counter)}]),
    %% timeout memory, auto clean
    mnesia:create_table(timeout_counter, [{disc_copies, [node()]},
                                        {type, set},
                                        {attributes, record_info(fields, timeout_counter)}]),
    %% daily counter, auto clean
    create_table_daily_counter(),
    mnesia:wait_for_tables([mapper, counter, timeout_counter], 10000),
    %% error_logger:info_msg("erl_counter_end"),
    restart_timertask().

get(Name) ->
	case mnesia:dirty_read(mapper, Name) of 
		[] -> undefined;
		[Mapper] -> Mapper#mapper.value
	end.

set(Name, Value) ->
	mnesia:dirty_write(mapper, #mapper{name = Name, value = Value}).

del(Name) ->
	mnesia:dirty_delete(mapper, Name).

get_timeout(Name) ->
	Now = time_utils:now(),
	case mnesia:dirty_read(timeout_counter, Name) of 
		[] -> undefined;
		[Counter] when Counter#timeout_counter.timeout =< Now  -> undefined;
		[Counter] -> Counter#timeout_counter.value
	end.

set_timeout(Name, Timeout, Value) ->
	case mnesia:dirty_read(timeout_counter, Name) of
		[] -> ok; 
		[_Counter] -> del_timeout(Name)
	end,
	mnesia:dirty_write(timeout_counter, #timeout_counter{name = Name, timeout = Timeout, value = Value}).

del_timeout(Name) ->
	mnesia:dirty_delete(timeout_counter, Name).

get_incr(Name) ->
	case mnesia:dirty_read(counter, Name) of 
		[] -> 0;
		[Counter] -> Counter#counter.value
	end.

incr(Name, Amount) ->
	mnesia:dirty_update_counter(counter, Name, Amount).

del_incr(Name) ->
	mnesia:dirty_delete(counter, Name).

create_table_daily_counter() ->
	mnesia:create_table(daily_counter, [{disc_copies, [node()]},
                                        {type, set},
                                        {attributes, record_info(fields, daily_counter)}]),
	mnesia:wait_for_tables([daily_counter], 10000).

incr_daily_counter(Name, Amount) ->
	mnesia:dirty_update_counter(daily_counter, {Name, date()}, Amount).

get_daily_counter(Name) ->
	case mnesia:dirty_read(daily_counter, {Name, date()}) of
		[] -> 0;
		[Rec] -> Rec#daily_counter.value 
	end.

del_daily_counter(Name) ->
	mnesia:dirty_delete(daily_counter, {Name, date()}).

clean_daily_counters() ->
	mnesia:delete_table(daily_counter),
	create_table_daily_counter().

clear_timeout_counter() ->
	Now = time_utils:now(),
	mnesia:transaction(fun()->
		MatchHead = #timeout_counter{name='$1', timeout='$2', _='_'},
		Guard = {'=<', '$2', Now},
		Result = '$1',
		Olds = mnesia:select(timeout_counter, [{MatchHead, [Guard], [Result]}]),
		%% error_logger:info_msg("clear_timeout_counter:~p~n", [Olds]),
		lists:foreach(fun(Name) ->
			del_timeout(Name)
		end, Olds)
	end).

restart_timertask() ->
	Now = time_utils:now(),
	{_, AccOut} = mnesia:transaction(fun()->
		mnesia:foldl(fun(Record, AccIn) ->
			case Record#timeout_counter.name of
				{timertask_desk, Key} when Record#timeout_counter.timeout > Now ->
					del_timeout({timertask_desk, Key}),
					[{Key, Record#timeout_counter.value}|AccIn];
				{timertask_desk, Key} -> 
					del_timeout({timertask_desk, Key}),
					AccIn;
				{timertask, Key} -> 
					del_timeout({timertask, Key}),
					AccIn;
				_ -> AccIn
			end
		end, [], timeout_counter)
	end),
	lists:foreach(fun({Key, {Time, _Ref, M, F, A}}) ->
		erl_timer_task:add(Time - Now, Key, M, F, A)
	end, AccOut).