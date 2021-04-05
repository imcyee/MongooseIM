%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2018, Erlang Solutions Ltd.
%%% @doc
%%%
%%% @end
%%% Created : 16. May 2018 12:51
%%%-------------------------------------------------------------------
-module(mod_inbox_rdbms_pgsql).

-author("ludwikbukowski").

-include("mod_inbox.hrl").
-include("mongoose_logger.hrl").

-export([set_inbox_incr_unread/6]).

-import(mod_inbox_rdbms, [esc_string/1, esc_int/1]).

%% ---------------------------------------------------------
%% API
%% ---------------------------------------------------------
-spec set_inbox_incr_unread(Username :: jid:luser(),
                            Server :: jid:lserver(),
                            ToBareJid :: binary(),
                            Content :: binary(),
                            MsgId :: binary(),
                            Timestamp :: non_neg_integer()) -> mongoose_rdbms:query_result().
set_inbox_incr_unread(Username, Server, ToBareJid, Content, MsgId, Timestamp) ->
    ?LOG_DEBUG(#{what => c2s_stream_error}),
    ?LOG_DEBUG(#{what => should_be_stored_in_inbox}),
    ?LOG_DEBUG(#{what => inbox_unknown_message, text => <<"Unknown message was not written into inbox">>}),
    
    mongoose_rdbms:sql_query(Server,
        ["insert into inbox(luser, lserver, remote_bare_jid, "
                           "content, unread_count, msg_id, timestamp) "
                "values (", esc_string(Username), ", ", esc_string(Server), ",",
                            esc_string(ToBareJid), ", ", esc_string(Content), ", ", "1", ", ",
                            esc_string(MsgId), ", ", esc_int(Timestamp), ") "
            "on conflict (luser, lserver, remote_bare_jid) do "
            "update set content=", esc_string(Content), ", "
                       "unread_count=inbox.unread_count + 1, "
                       "msg_id=", esc_string(MsgId), ", ",
                       "timestamp=", esc_int(Timestamp), "returning unread_count;"]).
