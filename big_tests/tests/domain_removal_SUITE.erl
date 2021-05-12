-module(domain_removal_SUITE).

%% API
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([mam_pm_removal/1,
         mam_muc_removal/1,
         inbox_removal/1,
         muc_light_removal/1,
         muc_light_blocking_removal/1]).

-import(distributed_helper, [mim/0, rpc/4, subhost_pattern/1]).

-include("mam_helper.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml_stream.hrl").

all() ->
    [{group, mam_removal},
     {group, inbox_removal},
     {group, muc_light_removal}].

groups() ->
    [
     {mam_removal, [], [mam_pm_removal,
                        mam_muc_removal]},
     {inbox_removal, [], [inbox_removal]},
     {muc_light_removal, [], [muc_light_removal,
                              muc_light_blocking_removal]}
    ].

domain() ->
    ct:get_config({hosts, mim, domain}).

%%%===================================================================
%%% Overall setup/teardown
%%%===================================================================
init_per_suite(Config) ->
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus:end_per_suite(Config).

%%%===================================================================
%%% Group specific setup/teardown
%%%===================================================================
init_per_group(Group, Config) ->
    case mongoose_helper:is_rdbms_enabled(domain()) of
        true ->
            Config2 = dynamic_modules:save_modules(domain(), Config),
            rpc(mim(), gen_mod_deps, start_modules, [domain(), group_to_modules(Group)]),
            Config2;
        false ->
            {skip, require_rdbms}
    end.

end_per_group(_Groupname, Config) ->
    case mongoose_helper:is_rdbms_enabled(domain()) of
        true ->
            dynamic_modules:restore_modules(domain(), Config);
        false ->
            ok
    end,
    ok.

group_to_modules(mam_removal) ->
    HostPattern = subhost_pattern(muc_light_helper:muc_host()),
    [{mod_mam_meta, [{backend, rdbms}, {pm, []}, {muc, [{host, HostPattern}]}]},
     {mod_muc_light, []}];
group_to_modules(muc_light_removal) ->
    [{mod_muc_light, [{backend, rdbms}]}];
group_to_modules(inbox_removal) ->
    [{mod_inbox, []}].

%%%===================================================================
%%% Testcase specific setup/teardown
%%%===================================================================

init_per_testcase(TestCase, Config) ->
    escalus:init_per_testcase(TestCase, Config).

end_per_testcase(TestCase, Config) ->
    escalus:end_per_testcase(TestCase, Config).

%%%===================================================================
%%% Test Cases
%%%===================================================================

mam_pm_removal(Config) ->
    F = fun(Alice, Bob) ->
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),
        escalus:wait_for_stanza(Bob),
        mam_helper:wait_for_archive_size(Alice, 1),
        mam_helper:wait_for_archive_size(Bob, 1),
        run_remove_domain(),
        mam_helper:wait_for_archive_size(Alice, 0),
        mam_helper:wait_for_archive_size(Bob, 0)
        end,
    escalus_fresh:story(Config, [{alice, 1}, {bob, 1}], F).

mam_muc_removal(Config0) ->
    F = fun(Config, Alice) ->
        Room = muc_helper:fresh_room_name(),
        MucHost = muc_light_helper:muc_host(),
        muc_light_helper:create_room(Room, MucHost, alice,
                                     [], Config, muc_light_helper:ver(1)),
        RoomAddr = <<Room/binary, "@", MucHost/binary>>,
        escalus:send(Alice, escalus_stanza:groupchat_to(RoomAddr, <<"text">>)),
        escalus:wait_for_stanza(Alice),
        mam_helper:wait_for_room_archive_size(MucHost, Room, 1),
        run_remove_domain(),
        mam_helper:wait_for_room_archive_size(MucHost, Room, 0)
        end,
    escalus_fresh:story_with_config(Config0, [{alice, 1}], F).

inbox_removal(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),
        escalus:wait_for_stanza(Bob),
        inbox_helper:get_inbox(Alice, #{count => 1}),
        inbox_helper:get_inbox(Bob, #{count => 1}),
        run_remove_domain(),
        inbox_helper:get_inbox(Alice, #{count => 0, unread_messages => 0, active_conversations => 0}),
        inbox_helper:get_inbox(Bob, #{count => 0, unread_messages => 0, active_conversations => 0})
      end).

muc_light_removal(Config0) ->
    F = fun(Config, Alice) ->
        %% GIVEN a room
        Room = muc_helper:fresh_room_name(),
        MucHost = muc_light_helper:muc_host(),
        muc_light_helper:create_room(Room, MucHost, alice,
                                     [], Config, muc_light_helper:ver(1)),
        RoomAddr = <<Room/binary, "@", MucHost/binary>>,
        escalus:send(Alice, escalus_stanza:groupchat_to(RoomAddr, <<"text">>)),
        escalus:wait_for_stanza(Alice),
        RoomID = select_room_id(domain(), Room, MucHost),
        {selected, [_]} = select_affs_by_room_id(domain(), RoomID),
        {selected, [_|_]} = select_config_by_room_id(domain(), RoomID),
        {ok, _RoomConfig, _AffUsers, _Version} = get_room_info(Room, MucHost),
        %% WHEN domain hook called
        run_remove_domain(),
        %% THEN Room info not available
        {error, not_exists} = get_room_info(Room, MucHost),
        %% THEN Tables are empty
        {selected, []} = select_affs_by_room_id(domain(), RoomID),
        {selected, []} = select_config_by_room_id(domain(), RoomID)
        end,
    escalus_fresh:story_with_config(Config0, [{alice, 1}], F).

muc_light_blocking_removal(Config0) ->
    F = fun(Config, Alice, Bob) ->
        %% GIVEN a room
        Room = muc_helper:fresh_room_name(),
        MucHost = muc_light_helper:muc_host(),
        muc_light_helper:create_room(Room, MucHost, alice,
                                     [], Config, muc_light_helper:ver(1)),
        block_muclight_user(Bob, Alice),
        [_] = get_blocking(Bob, MucHost),
        %% WHEN domain hook called
        run_remove_domain(),
        [] = get_blocking(Bob, MucHost)
        end,
    escalus_fresh:story_with_config(Config0, [{alice, 1}, {bob, 1}], F).

run_remove_domain() ->
    rpc(mim(), mongoose_hooks, remove_domain, [domain(), domain()]).

get_room_info(RoomU, RoomS) ->
    rpc(mim(), mod_muc_light_db_backend, get_info, [{RoomU, RoomS}]).

select_room_id(MainHost, RoomU, RoomS) ->
    {selected, [{DbRoomID}]} =
        rpc(mim(), mod_muc_light_db_rdbms, select_room_id, [MainHost, RoomU, RoomS]),
    rpc(mim(), mongoose_rdbms, result_to_integer, [DbRoomID]).

select_affs_by_room_id(MainHost, RoomID) ->
    rpc(mim(), mod_muc_light_db_rdbms, select_affs_by_room_id, [MainHost, RoomID]).

select_config_by_room_id(MainHost, RoomID) ->
    rpc(mim(), mod_muc_light_db_rdbms, select_config_by_room_id, [MainHost, RoomID]).

get_blocking(User, MUCServer) ->
    Jid = jid:from_binary(escalus_client:short_jid(User)),
    {LUser, LServer, _} = jid:to_lower(Jid),
    rpc(mim(), mod_muc_light_db_rdbms, get_blocking, [{LUser, LServer}, MUCServer]).

block_muclight_user(Bob, Alice) ->
    %% Bob blocks Alice
    AliceJIDBin = escalus_client:short_jid(Alice),
    BlocklistChange = [{user, deny, AliceJIDBin}],
    escalus:send(Bob, muc_light_helper:stanza_blocking_set(BlocklistChange)),
    escalus:assert(is_iq_result, escalus:wait_for_stanza(Bob)).
