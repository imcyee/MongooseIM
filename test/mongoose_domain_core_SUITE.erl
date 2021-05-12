-module(mongoose_domain_core_SUITE).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(STATIC_PAIRS, [{<<"example.cfg">>, <<"type #1">>},
                       {<<"erlang-solutions.com">>, <<"type #2">>},
                       {<<"erlang-solutions.local">>, <<"static type">>}, %% not allowed type
                       {<<"example.org">>, <<"type #2">>}]).
-define(ALLOWED_TYPES, [<<"type #1">>, <<"type #2">>, <<"type #3">>]).

-define(assertEqualLists(L1, L2), ?assertEqual(lists:sort(L1), lists:sort(L2))).

all() ->
    [can_get_init_arguments,
     lookup_works,
     double_insert_double_remove_works,
     static_domain_check,
     cannot_delete_static,
     cannot_insert_static_domain,
     cannot_insert_if_host_type_not_configured,
     get_all_static,
     get_domains_by_host_type,
     host_type_check,
     can_get_outdated_domains,
     run_for_each_domain].

init_per_suite(Config) ->
    meck:new(mongoose_hooks, [no_link]),
    meck:expect(mongoose_hooks, disable_domain, fun(_, _) -> ok end),
    Config.

end_per_suite(Config) ->
    meck:unload(),
    Config.

init_per_testcase(_, Config) ->
    ok = mongoose_domain_core:start(?STATIC_PAIRS, ?ALLOWED_TYPES),
    meck:reset(mongoose_hooks),
    Config.

end_per_testcase(_, Config) ->
    mongoose_domain_core:stop(),
    Config.

can_get_init_arguments(_) ->
    [?STATIC_PAIRS, ?ALLOWED_TYPES] = mongoose_domain_core:get_start_args().

lookup_works(_) ->
    {ok, <<"type #1">>} = mongoose_domain_core:get_host_type(<<"example.cfg">>),
    {ok, <<"static type">>} = mongoose_domain_core:get_host_type(<<"erlang-solutions.local">>),
    {error, not_found} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, dummy_src),
    {ok, <<"type #3">>} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = mongoose_domain_core:delete(<<"some.domain">>),
    {error, not_found} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = meck:wait(mongoose_hooks, disable_domain, [<<"type #3">>, <<"some.domain">>], 0).

double_insert_double_remove_works(_) ->
    {error, not_found} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, dummy_src),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, dummy_src),
    {ok, <<"type #3">>} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = mongoose_domain_core:delete(<<"some.domain">>),
    ok = mongoose_domain_core:delete(<<"some.domain">>),
    {error, not_found} = mongoose_domain_core:get_host_type(<<"some.domain">>),
    ok = meck:wait(mongoose_hooks, disable_domain, [<<"type #3">>, <<"some.domain">>], 0),
    1 = meck:num_calls(mongoose_hooks, disable_domain, 2).

static_domain_check(_) ->
    true = mongoose_domain_core:is_static(<<"example.cfg">>),
    false = mongoose_domain_core:is_static(<<"some.domain">>), %% not configured yet
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #1">>, dummy_src),
    false = mongoose_domain_core:is_static(<<"some.domain">>).

cannot_delete_static(_) ->
    {error, static} = mongoose_domain_core:delete(<<"example.cfg">>),
    {error, static} = mongoose_domain_core:delete(<<"erlang-solutions.local">>).

cannot_insert_static_domain(_) ->
    {error, static} = mongoose_domain_core:insert(<<"example.cfg">>, <<"type #1">>, dummy_src),
    {error, static} = mongoose_domain_core:insert(<<"erlang-solutions.local">>, <<"type #3">>,
                                                  dummy_src).

cannot_insert_if_host_type_not_configured(_) ->
    {ok, StaticHostType} = mongoose_domain_core:get_host_type(<<"erlang-solutions.local">>),
    {error, unknown_host_type} = mongoose_domain_core:insert(<<"erlang-solutions.local">>,
                                                             StaticHostType, dummy_src),
    {error, unknown_host_type} = mongoose_domain_core:insert(<<"erlang-solutions.local">>,
                                                             <<"invalid type">>, dummy_src).

%% See also db_get_all_static
get_all_static(_) ->
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #1">>, dummy_src),
    ?assertEqualLists(?STATIC_PAIRS, mongoose_domain_core:get_all_static()).

get_domains_by_host_type(_) ->
    ?assertEqualLists([<<"erlang-solutions.com">>, <<"example.org">>],
                      lists:sort(mongoose_domain_core:get_domains_by_host_type(<<"type #2">>))),
    [<<"example.cfg">>] = mongoose_domain_core:get_domains_by_host_type(<<"type #1">>),
    [<<"erlang-solutions.local">>] = mongoose_domain_core:get_domains_by_host_type(<<"static type">>),
    [] = mongoose_domain_core:get_domains_by_host_type(<<"invalid type">>),
    %% just no configured domains for this host type
    [] = mongoose_domain_core:get_domains_by_host_type(<<"type #3">>),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, dummy_src),
    [<<"some.domain">>] = mongoose_domain_core:get_domains_by_host_type(<<"type #3">>).

host_type_check(_) ->
    {ok, StaticHostType} = mongoose_domain_core:get_host_type(<<"erlang-solutions.local">>),
    false = mongoose_domain_core:is_host_type_allowed(StaticHostType),
    true = mongoose_domain_core:is_host_type_allowed(<<"type #1">>),
    true = mongoose_domain_core:is_host_type_allowed(<<"type #3">>),
    false = mongoose_domain_core:is_host_type_allowed(<<"invalid_type">>).

can_get_outdated_domains(_) ->
    [] = mongoose_domain_core:get_all_outdated(dummy_src),
    [] = mongoose_domain_core:get_all_outdated(another_dummy_src),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, dummy_src),
    ok = mongoose_domain_core:insert(<<"another.domain">>, <<"type #3">>, dummy_src),
    [] = mongoose_domain_core:get_all_outdated(dummy_src),
    ?assertEqualLists([{<<"some.domain">>, <<"type #3">>}, {<<"another.domain">>, <<"type #3">>}],
                      mongoose_domain_core:get_all_outdated(another_dummy_src)),
    %% reinserting record with another source
    ok = mongoose_domain_core:insert(<<"another.domain">>, <<"type #3">>, another_dummy_src),
    [{<<"another.domain">>, <<"type #3">>}] = mongoose_domain_core:get_all_outdated(dummy_src),
    [{<<"some.domain">>, <<"type #3">>}] = mongoose_domain_core:get_all_outdated(another_dummy_src),
    ok = mongoose_domain_core:insert(<<"some.domain">>, <<"type #3">>, another_dummy_src),
    [] = mongoose_domain_core:get_all_outdated(another_dummy_src),
    ?assertEqualLists([{<<"some.domain">>, <<"type #3">>}, {<<"another.domain">>, <<"type #3">>}],
                      mongoose_domain_core:get_all_outdated(dummy_src)),
    %% try to remove domains
    ok = mongoose_domain_core:delete(<<"some.domain">>),
    [{<<"another.domain">>, <<"type #3">>}] = mongoose_domain_core:get_all_outdated(dummy_src),
    [] = mongoose_domain_core:get_all_outdated(another_dummy_src),
    ok = mongoose_domain_core:delete(<<"another.domain">>),
    [] = mongoose_domain_core:get_all_outdated(dummy_src),
    [] = mongoose_domain_core:get_all_outdated(another_dummy_src).

run_for_each_domain(_) ->
    %% NumOfDomains is just some big non-round number to ensure that more than 2 ets
    %% selections are done during the call to mongoose_domain_core:for_each_domain/2.
    %% currently max selection size is 100 domains.
    NumOfDomains = 1234,
    NewDomains = [<<"dummy_domain_", (integer_to_binary(N))/binary, ".localhost">>
                  || N <- lists:seq(1, NumOfDomains)],
    [mongoose_domain_core:insert(Domain, <<"type #3">>, dummy_src) || Domain <- NewDomains],
    meck:new(dummy_module, [non_strict]),
    meck:expect(dummy_module, for_each_callback, fun(_, _) -> ok end),
    mongoose_domain_core:for_each_domain(<<"type #3">>, fun dummy_module:for_each_callback/2),
    NumOfDomains = meck:num_calls(dummy_module, for_each_callback, 2),
    [meck:wait(dummy_module, for_each_callback, [<<"type #3">>, Domain], 0)
     || Domain <- NewDomains],
    meck:unload(dummy_module).
