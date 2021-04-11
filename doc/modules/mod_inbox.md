## Module Description

`Inbox` is an experimental feature implemented as a few separate modules.
To use it, enable mod\_inbox in the config file.

## Options

### `modules.mod_inbox.reset_markers`
* **Syntax:** array of strings, out of `"displayed"`, `"received"`, `"acknowledged"`
* **Default:** `["displayed"]`
* **Example:** `reset_markers = ["received"]`

List of chat markers that when sent, will reset the unread message counter for a conversation.
This works when [Chat Markers](https://xmpp.org/extensions/xep-0333.html) are enabled on the client side.
Setting as empty list (not recommended) means that no chat marker can decrease the counter value.

### `modules.mod_inbox.groupchat`
* **Syntax:** array of strings
* **Default:** `["muclight"]`
* **Example:** `groupchat = ["muclight"]`

The list indicating which groupchats will be included in inbox.
Possible values are `muclight` [Multi-User Chat Light](https://xmpp.org/extensions/inbox/muc-light.html) or `muc` [Multi-User Chat](https://xmpp.org/extensions/xep-0045.html).

### `modules.mod_inbox.aff_changes`
* **Syntax:** boolean
* **Default:** `true`
* **Example:** `aff_changes = true`

Use this option when `muclight` is enabled.
Indicates if MUC Light affiliation change messages should be included in the conversation inbox.
Only changes that affect the user directly will be stored in their inbox.

### `modules.mod_inbox.remove_on_kicked`
* **Syntax:** boolean
* **Default:** `true`
* **Example:** `remove_on_kicked = true`

Use this option when `muclight` is enabled.
If true, the inbox conversation is removed for a user when they are removed from the groupchat.

### `modules.mod_inbox.iqdisc.type`
* **Syntax:** string, one of `"one_queue"`, `"no_queue"`, `"queues"`, `"parallel"`
* **Default:** `"no_queue"`

Strategy to handle incoming stanzas. For details, please refer to
[IQ processing policies](../../advanced-configuration/Modules/#iq-processing-policies).

## Note about supported RDBMS

`mod_inbox` executes upsert queries, which have different syntax in every supported RDBMS.
Inbox currently supports the following DBs:

* MySQL via native driver
* PgSQL via native driver
* MSSQL via ODBC driver

## Legacy MUC support
Inbox comes with support for the legacy MUC as well. It stores all groupchat messages sent to
room in each sender's and recipient's inboxes and private messages. Currently it is not possible to
configure it to store system messages like [subject](https://xmpp.org/extensions/xep-0045.html#enter-subject) 
or [affiliation](https://xmpp.org/extensions/xep-0045.html#affil) change.


## Example configuration

```toml
[modules.mod_inbox]
  reset_markers = ["displayed"]
  aff_changes = true
  remove_on_kicked = true
  groupchat = ["muclight"]
```
