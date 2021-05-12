%%==============================================================================
%% Copyright 2014 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(auth_http_SUITE).
-compile(export_all).
-author('piotr.nosek@erlang-solutions.com').

-include_lib("common_test/include/ct.hrl").

-define(DOMAIN, <<"localhost">>).
-define(HOST_TYPE, ?DOMAIN).
-define(AUTH_HOST, "http://localhost:12000").
-define(BASIC_AUTH, "softkitty:purrpurrpurr").

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, auth_requests_plain}, {group, auth_requests_scram}].

groups() ->
    [
     {cert_auth, cert_auth()},
     {auth_requests_plain, [sequence], all_tests()},
     {auth_requests_scram, [sequence], [{group,cert_auth} | all_tests()]}
    ].

all_tests() ->
    [
     check_password,
     set_password,
     try_register,
     get_password,
     does_user_exist,
     remove_user,
     supported_sasl_mechanisms
    ].

cert_auth() ->
    [
        cert_auth_fail,
        cert_auth_success,
        cert_auth_nonexistent
    ].

suite() ->
    [].

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(jid),
    meck_config(Config),
    mim_ct_rest:start(?BASIC_AUTH, Config),
    % Separate process needs to do this, because this one will terminate
    % so will supervisor and children and ETS tables
    mim_ct_rest:do(
      fun() ->
              mim_ct_sup:start_link(ejabberd_sup),
              mongoose_wpool:ensure_started(),
              % This would be started via outgoing_pools in normal case
              Pool = {http, host, auth,
                      [{strategy, random_worker}, {call_timeout, 5000}, {workers, 20}],
                      [{path_prefix, "/auth/"}, {http_opts, []}, {server, ?AUTH_HOST}]},
              Hosts = [?DOMAIN, <<"another.domain">>],
              mongoose_wpool:start_configured_pools([Pool], Hosts),
              mongoose_wpool_http:init(),
              ejabberd_auth_http:start(?HOST_TYPE)
      end),
    meck_cleanup(),
    Config.

end_per_suite(Config) ->
    ejabberd_auth_http:stop(?HOST_TYPE),
    ok = mim_ct_rest:stop(),
    Config.

init_per_group(cert_auth, Config) ->
    Root = small_path_helper:repo_dir(Config),
    SslDir = filename:join(Root, "tools/ssl"),
    try
        {ok, Cert1} = file:read_file(filename:join(SslDir, "mongooseim/cert.pem")),
        {ok, Cert2} = file:read_file(filename:join(SslDir,  "ca/cacert.pem")),
        [{'Certificate', DerBin, not_encrypted} | _] = public_key:pem_decode(Cert2),
        [{der_cert, DerBin}, {pem_cert1, Cert1}, {pem_cert2, Cert2} | Config]
    catch
        _:E ->
            {skip, {E, SslDir, element(2, file:get_cwd())}}
    end;
init_per_group(GroupName, Config) ->
    Config2 = lists:keystore(scram_group, 1, Config,
                             {scram_group, GroupName == auth_requests_scram}),
    meck_config(Config2),
    mim_ct_rest:register(<<"alice">>, ?DOMAIN, do_scram(<<"makota">>, Config2)),
    mim_ct_rest:register(<<"bob">>, ?DOMAIN, do_scram(<<"niema5klepki">>, Config2)),
    meck_cleanup(),
    Config2.

end_per_group(cert_auth, Config) ->
    Config;
end_per_group(_GroupName, Config) ->
    mim_ct_rest:remove_user(<<"alice">>, ?DOMAIN),
    mim_ct_rest:remove_user(<<"bob">>, ?DOMAIN),
    Config.

init_per_testcase(remove_user, Config) ->
    meck_config(Config),
    mim_ct_rest:register(<<"toremove1">>, ?DOMAIN, do_scram(<<"pass">>, Config)),
    mim_ct_rest:register(<<"toremove2">>, ?DOMAIN, do_scram(<<"pass">>, Config)),
    Config;
init_per_testcase(cert_auth_fail, Config) ->
    meck_config(Config),
    Cert = proplists:get_value(pem_cert1, Config),
    mim_ct_rest:register(<<"cert_user">>, ?DOMAIN, Cert),
    Config;
init_per_testcase(cert_auth_success, Config) ->
    meck_config(Config),
    Cert1 = proplists:get_value(pem_cert1, Config),
    Cert2 = proplists:get_value(pem_cert2, Config),
    SeveralCerts = <<Cert1/bitstring, Cert2/bitstring>>,
    mim_ct_rest:register(<<"cert_user">>, ?DOMAIN, SeveralCerts),
    Config;
init_per_testcase(_CaseName, Config) ->
    meck_config(Config),
    Config.

end_per_testcase(try_register, Config) ->
    mim_ct_rest:remove_user(<<"nonexistent">>, ?DOMAIN),
    meck_cleanup(),
    Config;
end_per_testcase(remove_user, Config) ->
    mim_ct_rest:remove_user(<<"toremove1">>, ?DOMAIN),
    mim_ct_rest:remove_user(<<"toremove2">>, ?DOMAIN),
    meck_cleanup(),
    Config;
end_per_testcase(cert_auth_fail, Config) ->
    mim_ct_rest:remove_user(<<"cert_user">>, ?DOMAIN),
    meck_cleanup(),
    Config;
end_per_testcase(cert_auth_success, Config) ->
    mim_ct_rest:remove_user(<<"cert_user">>, ?DOMAIN),
    meck_cleanup(),
    Config;
end_per_testcase(_CaseName, Config) ->
    meck_cleanup(),
    Config.

%%--------------------------------------------------------------------
%% Authentication tests
%%--------------------------------------------------------------------

check_password(_Config) ->
    true = ejabberd_auth_http:check_password(?HOST_TYPE, <<"alice">>,
                                             ?DOMAIN, <<"makota">>),
    false = ejabberd_auth_http:check_password(?HOST_TYPE, <<"alice">>,
                                              ?DOMAIN, <<"niemakota">>),
    false = ejabberd_auth_http:check_password(?HOST_TYPE, <<"kate">>,
                                              ?DOMAIN, <<"mapsa">>).

set_password(_Config) ->
    ok = ejabberd_auth_http:set_password(?HOST_TYPE, <<"alice">>,
                                         ?DOMAIN, <<"mialakota">>),
    true = ejabberd_auth_http:check_password(?HOST_TYPE, <<"alice">>,
                                             ?DOMAIN, <<"mialakota">>),
    ok = ejabberd_auth_http:set_password(?HOST_TYPE, <<"alice">>,
                                         ?DOMAIN, <<"makota">>).

try_register(_Config) ->
    ok = ejabberd_auth_http:try_register(?HOST_TYPE, <<"nonexistent">>,
                                         ?DOMAIN, <<"newpass">>),
    true = ejabberd_auth_http:check_password(?HOST_TYPE, <<"nonexistent">>,
                                             ?DOMAIN, <<"newpass">>),
    {error, exists} = ejabberd_auth_http:try_register(?HOST_TYPE, <<"nonexistent">>,
                                                      ?DOMAIN, <<"anypass">>).

% get_password + get_password_s
get_password(_Config) ->
    case mongoose_scram:enabled(?DOMAIN) of
        false ->
            <<"makota">> = ejabberd_auth_http:get_password(<<"alice">>, ?DOMAIN),
            <<"makota">> = ejabberd_auth_http:get_password_s(<<"alice">>, ?DOMAIN);
        true ->
            % map with SCRAM data
            is_map(ejabberd_auth_http:get_password(<<"alice">>, ?DOMAIN)),
            <<>> = ejabberd_auth_http:get_password_s(<<"alice">>, ?DOMAIN)
    end,
    false = ejabberd_auth_http:get_password(<<"anakin">>, ?DOMAIN),
    <<>> = ejabberd_auth_http:get_password_s(<<"anakin">>, ?DOMAIN).

does_user_exist(_Config) ->
    true = ejabberd_auth_http:does_user_exist(<<"alice">>, ?DOMAIN),
    false = ejabberd_auth_http:does_user_exist(<<"madhatter">>, ?DOMAIN).

% remove_user/2
remove_user(_Config) ->
    true = ejabberd_auth_http:does_user_exist(<<"toremove1">>, ?DOMAIN),
    ok = ejabberd_auth_http:remove_user(<<"toremove1">>, ?DOMAIN),
    false = ejabberd_auth_http:does_user_exist(<<"toremove1">>, ?DOMAIN).

supported_sasl_mechanisms(Config) ->
    Modules = [cyrsasl_plain, cyrsasl_digest, cyrsasl_external,
               cyrsasl_scram_sha1, cyrsasl_scram_sha224, cyrsasl_scram_sha256,
               cyrsasl_scram_sha384, cyrsasl_scram_sha512],
    DigestSupported = case lists:keyfind(scram_group, 1, Config) of
                          {_, true} -> false;
                          _ -> true
                      end,
    [true, DigestSupported, false, true, true, true, true, true] =
        [ejabberd_auth_http:supports_sasl_module(?DOMAIN, Mod) || Mod <- Modules].

cert_auth_fail(Config) ->
    Creds = creds_with_cert(Config, <<"cert_user">>),
    {error, not_authorized} = ejabberd_auth_http:authorize(Creds).

cert_auth_success(Config) ->
    Creds = creds_with_cert(Config, <<"cert_user">>),
    {ok, _} = ejabberd_auth_http:authorize(Creds).

cert_auth_nonexistent(Config) ->
    Creds = creds_with_cert(Config, <<"nonexistent">>),
    {error, not_authorized} = ejabberd_auth_http:authorize(Creds).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
creds_with_cert(Config, Username) ->
    Cert = proplists:get_value(der_cert, Config),
    NewCreds = mongoose_credentials:new(?DOMAIN, ?HOST_TYPE),
    mongoose_credentials:extend(NewCreds, [{der_cert, Cert},
                                           {username, Username}]).

meck_config(Config) ->
    meck:unload(),
    ScramOpts = case lists:keyfind(scram_group, 1, Config) of
                    {_, false} -> [{password_format, plain}];
                    _ -> []
                end,
    meck:new(ejabberd_config),
    meck:expect(ejabberd_config, get_local_option,
                fun(auth_opts, _Host) ->
                        [
                         {host, ?AUTH_HOST},
                         {path_prefix, "/auth/"},
                         {basic_auth, ?BASIC_AUTH}
                        ] ++ ScramOpts
                end).

meck_cleanup() ->
    meck:validate(ejabberd_config),
    meck:unload(ejabberd_config).

do_scram(Pass, Config) ->
    case lists:keyfind(scram_group, 1, Config) of
        {_, true} ->
            Iterations =  mongoose_scram:iterations(?HOST_TYPE),
            Scram = mongoose_scram:password_to_scram(?HOST_TYPE, Pass, Iterations),
            mongoose_scram:serialize(Scram);
        _ ->
            Pass
    end.
