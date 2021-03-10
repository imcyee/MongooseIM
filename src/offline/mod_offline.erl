%%%----------------------------------------------------------------------
%%% File    : mod_offline.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Store and manage offline messages
%%% See     : XEP-0160: Best Practices for Handling Offline Messages
%%% Created :  5 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_offline).
-author('alexey@process-one.net').
-xep([{xep, 160}, {version, "1.0"}]).
-xep([{xep, 23}, {version, "1.3"}]).
-xep([{xep, 22}, {version, "1.4"}]).
-xep([{xep, 85}, {version, "2.1"}]).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

%% gen_mod handlers
-export([start/2, stop/1, config_spec/0]).

%% Hook handlers
-export([inspect_packet/4,
         pop_offline_messages/2,
         get_sm_features/5,
         remove_expired_messages/1,
         remove_old_messages/2,
         remove_user/2, % for tests
         remove_user/3,
         determine_amp_strategy/5,
         amp_failed_event/1]).

%% Internal exports
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% helpers to be used from backend moudules
-export([is_expired_message/2]).

%% GDPR related
-export([get_personal_data/2]).

-export([config_metrics/1]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include("amp.hrl").
-include("mod_offline.hrl").
-include("mongoose_config_spec.hrl").

-define(PROCNAME, ejabberd_offline).

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).

-type msg() :: #offline_msg{us :: {jid:luser(), jid:lserver()},
                          timestamp :: integer(),
                          expire :: integer() | never,
                          from ::jid:jid(),
                          to ::jid:jid(),
                          packet :: exml:element()}.

-export_type([msg/0]).

-record(state, {
    host :: jid:server(),
    access_max_user_messages,
    message_poppers = monitored_map:new() ::
        monitored_map:t({LUser :: binary(), LServer :: binary}, pid())
}).

%% ------------------------------------------------------------------
%% Backend callbacks

-callback init(Host, Opts) -> ok when
    Host :: binary(),
    Opts :: list().
-callback pop_messages(JID) -> {ok, Result} | {error, Reason} when
    JID :: jid:jid(),
    Reason :: term(),
    Result :: list(#offline_msg{}).
-callback fetch_messages(JID) -> {ok, Result} | {error, Reason} when
    JID :: jid:jid(),
    Reason :: term(),
    Result :: list(#offline_msg{}).
-callback write_messages(LUser, LServer, Msgs) ->
    ok | {error, Reason}  when
    LUser :: jid:luser(),
    LServer :: jid:lserver(),
    Msgs :: list(),
    Reason :: term().
-callback count_offline_messages(LUser, LServer, MaxToArchive) -> integer() when
      LUser :: jid:luser(),
      LServer :: jid:lserver(),
      MaxToArchive :: integer().
-callback remove_expired_messages(Host) -> {error, Reason} | {ok, Count} when
    Host :: jid:lserver(),
    Reason :: term(),
    Count :: integer().
-callback remove_old_messages(Host, Timestamp) -> {error, Reason} | {ok, Count} when
    Host :: jid:lserver(),
    Timestamp :: integer(),
    Reason :: term(),
    Count :: integer().
-callback remove_user(LUser, LServer) -> any() when
    LUser :: binary(),
    LServer :: binary().

%% gen_mod callbacks
%% ------------------------------------------------------------------

start(Host, Opts) ->
    AccessMaxOfflineMsgs = gen_mod:get_opt(access_max_user_messages, Opts,
                                           max_user_offline_messages),
    gen_mod:start_backend_module(?MODULE, Opts, [pop_messages, write_messages]),
    mod_offline_backend:init(Host, Opts),
    start_worker(Host, AccessMaxOfflineMsgs),
    ejabberd_hooks:add(hooks(Host)),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(hooks(Host)),
    stop_worker(Host),
    ok.

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{
       items = #{<<"access_max_user_messages">> => #option{type = atom,
                                                           validate = access_rule},
                 <<"backend">> => #option{type = atom,
                                          validate = {module, mod_offline}},
                 <<"riak">> => riak_config_spec()
                }
      }.

riak_config_spec() ->
    #section{items = #{<<"bucket_type">> => #option{type = binary,
                                                     validate = non_empty}},
             format = none
            }.

hooks(Host) ->
    DefaultHooks = [
        {offline_message_hook, Host, ?MODULE, inspect_packet, 50},
        {resend_offline_messages_hook, Host, ?MODULE, pop_offline_messages, 50},
        {remove_user, Host, ?MODULE, remove_user, 50},
        {anonymous_purge_hook, Host, ?MODULE, remove_user, 50},
        {disco_sm_features, Host, ?MODULE, get_sm_features, 50},
        {disco_local_features, Host, ?MODULE, get_sm_features, 50},
        {amp_determine_strategy, Host, ?MODULE, determine_amp_strategy, 30},
        {failed_to_store_message, Host, ?MODULE, amp_failed_event, 30},
        {get_personal_data, Host, ?MODULE, get_personal_data, 50}
    ],
    case gen_mod:get_module_opt(Host, ?MODULE, store_groupchat_messages, false) of
        true ->
            GroupChatHook = {offline_groupchat_message_hook,
                             Host, ?MODULE, inspect_packet, 50},
            [GroupChatHook | DefaultHooks];
        _ -> DefaultHooks
    end.

%% Server side functions
%% ------------------------------------------------------------------

amp_failed_event(Acc) ->
    mod_amp:check_packet(Acc, offline_failed).

handle_offline_msg(Acc, #offline_msg{us=US} = Msg, AccessMaxOfflineMsgs) ->
    {LUser, LServer} = US,
    Msgs = receive_all(US, [{Acc, Msg}]),
    MaxOfflineMsgs = get_max_user_messages(AccessMaxOfflineMsgs, LUser, LServer),
    Len = length(Msgs),
    case is_message_count_threshold_reached(MaxOfflineMsgs, LUser, LServer, Len) of
        false ->
            write_messages(LUser, LServer, Msgs);
        true ->
            discard_warn_sender(Msgs)
    end.

write_messages(LUser, LServer, Msgs) ->
    MsgsWithoutAcc = [Msg || {_Acc, Msg} <- Msgs],
    case mod_offline_backend:write_messages(LUser, LServer, MsgsWithoutAcc) of
        ok ->
            [mod_amp:check_packet(Acc, archived) || {Acc, _Msg} <- Msgs],
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{what => offline_write_failed,
                         text => <<"Failed to write offline messages">>,
                         reason => Reason,
                         user => LUser, server => LServer, msgs => Msgs}),
            discard_warn_sender(Msgs)
    end.

-spec is_message_count_threshold_reached(integer(), jid:luser(),
                                         jid:lserver(), integer()) ->
    boolean().
is_message_count_threshold_reached(infinity, _LUser, _LServer, _Len) ->
    false;
is_message_count_threshold_reached(MaxOfflineMsgs, _LUser, _LServer, Len)
  when Len > MaxOfflineMsgs ->
    true;
is_message_count_threshold_reached(MaxOfflineMsgs, LUser, LServer, Len) ->
    %% Only count messages if needed.
    MaxArchivedMsg = MaxOfflineMsgs - Len,
    %% Maybe do not need to count all messages in archive
    MaxArchivedMsg < mod_offline_backend:count_offline_messages(LUser, LServer, MaxArchivedMsg + 1).


get_max_user_messages(AccessRule, LUser, Host) ->
    case acl:match_rule(Host, AccessRule, jid:make_noprep(LUser, Host, <<>>)) of
        Max when is_integer(Max) -> Max;
        infinity -> infinity;
        _ -> ?MAX_USER_MESSAGES
    end.

receive_all(US, Msgs) ->
    receive
        {_Acc, #offline_msg{us=US}} = Msg ->
            receive_all(US, [Msg | Msgs])
    after 0 ->
              Msgs
    end.

%% Supervision
%% ------------------------------------------------------------------

start_worker(Host, AccessMaxOfflineMsgs) ->
    Proc = srv_name(Host),
    ChildSpec =
    {Proc,
     {?MODULE, start_link, [Proc, Host, AccessMaxOfflineMsgs]},
     permanent, 5000, worker, [?MODULE]},
    ejabberd_sup:start_child(ChildSpec).

stop_worker(Host) ->
    Proc = srv_name(Host),
    ejabberd_sup:stop_child(Proc).

start_link(Name, Host, AccessMaxOfflineMsgs) ->
    gen_server:start_link({local, Name}, ?MODULE, [Host, AccessMaxOfflineMsgs], []).

srv_name() ->
    mod_offline.

srv_name(Host) ->
    gen_mod:get_module_proc(Host, srv_name()).

determine_amp_strategy(Strategy = #amp_strategy{deliver = [none]},
                       _FromJID, ToJID, _Packet, initial_check) ->
    case ejabberd_auth:does_user_exist(ToJID) of
        true -> Strategy#amp_strategy{deliver = [stored, none]};
        false -> Strategy
    end;
determine_amp_strategy(Strategy, _, _, _, _) ->
    Strategy.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, AccessMaxOfflineMsgs]) ->
    {ok, #state{
            host = Host,
            access_max_user_messages = AccessMaxOfflineMsgs}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({pop_offline_messages, JID}, {Pid, _}, State) ->
    Result = mod_offline_backend:pop_messages(JID),
    NewPoppers = monitored_map:put(jid:to_lus(JID), Pid, Pid, State#state.message_poppers),
    {reply, Result, State#state{message_poppers = NewPoppers}};
handle_call(Request, From, State) ->
    ?UNEXPECTED_CALL(Request, From),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
    ?UNEXPECTED_CAST(Msg),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', _MonitorRef, _Type, _Object, _Info} = Msg, State) ->
    NewPoppers = monitored_map:handle_info(Msg, State#state.message_poppers),
    {noreply, State#state{message_poppers = NewPoppers}};
handle_info({Acc, Msg = #offline_msg{us = US}},
            State = #state{access_max_user_messages = AccessMaxOfflineMsgs}) ->
    handle_offline_msg(Acc, Msg, AccessMaxOfflineMsgs),
    case monitored_map:find(US, State#state.message_poppers) of
        {ok, Pid} ->
            Pid ! new_offline_messages;
        error -> ok
    end,
    {noreply, State};
handle_info(Msg, State) ->
    ?UNEXPECTED_INFO(Msg),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Handlers
%% ------------------------------------------------------------------

get_sm_features(Acc, _From, _To, <<"">> = _Node, _Lang) ->
    add_feature(Acc, ?NS_FEATURE_MSGOFFLINE);
get_sm_features(_Acc, _From, _To, ?NS_FEATURE_MSGOFFLINE, _Lang) ->
    %% override all lesser features...
    {result, []};
get_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

add_feature({result, Features}, Feature) ->
    {result, Features ++ [Feature]};
add_feature(_, Feature) ->
    {result, [Feature]}.

%% This function should be called only from a hook
%% Calling it directly is dangerous and may store unwanted messages
%% in the offline storage (e.g. messages of type error)
%% #rh
inspect_packet(Acc, From, To, Packet) ->
    case check_event_chatstates(Acc, From, To, Packet) of
        true ->
            Acc1 = store_packet(Acc, From, To, Packet),
            {stop, Acc1};
        false ->
            Acc
    end.

store_packet(Acc, From, To = #jid{luser = LUser, lserver = LServer},
             Packet = #xmlel{children = Els}) ->
    TimeStamp = get_or_build_timestamp_from_packet(Packet),
    Expire = find_x_expire(TimeStamp, Els),
    Pid = srv_name(LServer),
    PermanentFields = mongoose_acc:get_permanent_fields(Acc),
    Msg = #offline_msg{us = {LUser, LServer},
                       timestamp = TimeStamp,
                       expire = Expire,
                       from = From,
                       to = To,
                       packet = jlib:remove_delay_tags(Packet),
                       permanent_fields = PermanentFields},
    Pid ! {Acc, Msg},
    mongoose_acc:set(offline, stored, true, Acc).

-spec get_or_build_timestamp_from_packet(exml:element()) -> integer().
get_or_build_timestamp_from_packet(Packet) ->
    case exml_query:path(Packet, [{element, <<"delay">>}, {attr, <<"stamp">>}]) of
        undefined ->
            erlang:system_time(microsecond);
        Stamp ->
            try
                calendar:rfc3339_to_system_time(binary_to_list(Stamp), [{unit, microsecond}])
            catch
                error:_Error -> erlang:system_time(microsecond)
            end
    end.

%% Check if the packet has any content about XEP-0022 or XEP-0085
check_event_chatstates(Acc, From, To, Packet) ->
    #xmlel{children = Els} = Packet,
    case find_x_event_chatstates(Els, {false, false, false}) of
        %% There wasn't any x:event or chatstates subelements
        {false, false, _} ->
            true;
        %% There a chatstates subelement and other stuff, but no x:event
        {false, CEl, true} when CEl /= false ->
            true;
        %% There was only a subelement: a chatstates
        {false, CEl, false} when CEl /= false ->
            %% Don't allow offline storage
            false;
        %% There was an x:event element, and maybe also other stuff
        {El, _, _} when El /= false ->
            inspect_xevent(Acc, From, To, Packet, El)
    end.

inspect_xevent(Acc, From, To, Packet, XEvent) ->
    case exml_query:subelement(XEvent, <<"id">>) of
        undefined ->
            case exml_query:subelement(XEvent, <<"offline">>) of
                undefined ->
                    true;
                _ ->
                    ejabberd_router:route(To, From, Acc, patch_offline_message(Packet)),
                    true
            end;
        _ ->
            false
    end.

patch_offline_message(Packet) ->
    ID = case exml_query:attr(Packet, <<"id">>, <<>>) of
             <<"">> -> #xmlel{name = <<"id">>};
             S -> #xmlel{name = <<"id">>, children = [#xmlcdata{content = S}]}
         end,
    Packet#xmlel{children = [x_elem(ID)]}.

x_elem(ID) ->
    #xmlel{
        name = <<"x">>,
        attrs = [{<<"xmlns">>, ?NS_EVENT}],
        children = [ID, #xmlel{name = <<"offline">>}]}.

%% Check if the packet has subelements about XEP-0022, XEP-0085 or other
find_x_event_chatstates([], Res) ->
    Res;
find_x_event_chatstates([#xmlcdata{} | Els], Res) ->
    find_x_event_chatstates(Els, Res);
find_x_event_chatstates([El | Els], {A, B, C}) ->
    case exml_query:attr(El, <<"xmlns">>, <<>>) of
        ?NS_EVENT -> find_x_event_chatstates(Els, {El, B, C});
        ?NS_CHATSTATES -> find_x_event_chatstates(Els, {A, El, C});
        _ -> find_x_event_chatstates(Els, {A, B, true})
    end.

find_x_expire(_, []) ->
    never;
find_x_expire(TimeStamp, [#xmlcdata{} | Els]) ->
    find_x_expire(TimeStamp, Els);
find_x_expire(TimeStamp, [El | Els]) ->
    case exml_query:attr(El, <<"xmlns">>, <<>>) of
        ?NS_EXPIRE ->
            Val = exml_query:attr(El, <<"seconds">>, <<>>),
            try binary_to_integer(Val) of
                Int when Int > 0 ->
                    ExpireMicroSeconds = erlang:convert_time_unit(Int, second, microsecond),
                    TimeStamp + ExpireMicroSeconds;
                _ ->
                    never
            catch
                error:badarg -> never
            end;
        _ ->
            find_x_expire(TimeStamp, Els)
    end.

pop_offline_messages(Acc, JID) ->
    mongoose_acc:append(offline, messages, offline_messages(Acc, JID), Acc).

offline_messages(Acc, #jid{lserver = LServer} = JID) ->
    case pop_messages(JID) of
        {ok, Rs} ->
            lists:map(fun(R) ->
                Packet = resend_offline_message_packet(LServer, R),
                compose_offline_message(R, Packet, Acc)
              end, Rs);
        {error, Reason} ->
            ?LOG_WARNING(#{what => offline_pop_failed, reason => Reason, acc => Acc}),
            []
    end.

pop_messages(#jid{lserver = LServer} = JID) ->
    case gen_server:call(srv_name(LServer), {pop_offline_messages, jid:to_bare(JID)}) of
        {ok, RsAll} ->
            TimeStamp = erlang:system_time(microsecond),
            Rs = skip_expired_messages(TimeStamp, lists:keysort(#offline_msg.timestamp, RsAll)),
            {ok, Rs};
        Other ->
            Other
    end.

get_personal_data(Acc, #jid{} = JID) ->
    {ok, Messages} = mod_offline_backend:fetch_messages(JID),
    [ {offline, ["timestamp", "from", "to", "packet"],
       offline_messages_to_gdpr_format(Messages)} | Acc].

offline_messages_to_gdpr_format(MsgList) ->
    [offline_msg_to_gdpr_format(Msg) || Msg <- MsgList].

offline_msg_to_gdpr_format(#offline_msg{timestamp = TimeStamp, from = From,
                                        to = To, packet = Packet}) ->
    SystemTime = erlang:convert_time_unit(TimeStamp, microsecond, second),
    UTCTime = calendar:system_time_to_rfc3339(SystemTime, [{offset, "Z"}]),
    UTC = list_to_binary(UTCTime),
    {UTC, jid:to_binary(From), jid:to_binary(jid:to_bare(To)), exml:to_binary(Packet)}.

skip_expired_messages(TimeStamp, Rs) ->
    [R || R <- Rs, not is_expired_message(TimeStamp, R)].

is_expired_message(_TimeStamp, #offline_msg{expire=never}) ->
    false;
is_expired_message(TimeStamp, #offline_msg{expire=ExpireTimeStamp}) ->
   ExpireTimeStamp < TimeStamp.

compose_offline_message(#offline_msg{from = From, to = To, permanent_fields = PermanentFields},
                        Packet, Acc0) ->
    Acc1 = mongoose_acc:set_permanent(PermanentFields, Acc0),
    Acc = mongoose_acc:update_stanza(#{element => Packet, from_jid => From, to_jid => To}, Acc1),
    {route, From, To, Acc}.

resend_offline_message_packet(LServer,
        #offline_msg{timestamp=TimeStamp, packet = Packet}) ->
    add_timestamp(TimeStamp, LServer, Packet).

add_timestamp(undefined, _LServer, Packet) ->
    Packet;
add_timestamp(TimeStamp, LServer, Packet) ->
    TimeStampXML = timestamp_xml(LServer, TimeStamp),
    xml:append_subtags(Packet, [TimeStampXML]).

timestamp_xml(LServer, Time) ->
    FromJID = jid:make_noprep(<<>>, LServer, <<>>),
    TS = calendar:system_time_to_rfc3339(Time, [{offset, "Z"}, {unit, microsecond}]),
    jlib:timestamp_to_xml(TS, FromJID, <<"Offline Storage">>).

remove_expired_messages(Host) ->
    Result = mod_offline_backend:remove_expired_messages(Host),
    mongoose_lib:log_if_backend_error(Result, ?MODULE, ?LINE, [Host]),
    Result.

remove_old_messages(Host, HowManyDays) ->
    Timestamp = fallback_timestamp(HowManyDays, erlang:system_time(microsecond)),
    Result = mod_offline_backend:remove_old_messages(Host, Timestamp),
    mongoose_lib:log_if_backend_error(Result, ?MODULE, ?LINE, [Host, Timestamp]),
    Result.

%% #rh

remove_user(Acc, User, Server) ->
    remove_user(User, Server),
    Acc.

remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    mod_offline_backend:remove_user(LUser, LServer).

%% Warn senders that their messages have been discarded:
discard_warn_sender(Msgs) ->
    lists:foreach(
      fun({Acc, #offline_msg{from=From, to=To, packet=Packet}}) ->
              ErrText = <<"Your contact offline message queue is full."
                          " The message has been discarded.">>,
              Lang = exml_query:attr(Packet, <<"xml:lang">>, <<>>),
              amp_failed_event(Acc),
              {Acc1, Err} = jlib:make_error_reply(
                      Acc, Packet, mongoose_xmpp_errors:resource_constraint(Lang, ErrText)),
              ejabberd_router:route(To, From, Acc1, Err)
      end, Msgs).

fallback_timestamp(HowManyDays, TS_MicroSeconds) ->
    HowManySeconds = HowManyDays * 86400,
    HowManyMicroSeconds = erlang:convert_time_unit(HowManySeconds, second, microsecond),
    TS_MicroSeconds - HowManyMicroSeconds.

config_metrics(Host) ->
    OptsToReport = [{backend, mnesia}], %list of tuples {option, default_value}
    mongoose_module_metrics:opts_for_module(Host, ?MODULE, OptsToReport).
