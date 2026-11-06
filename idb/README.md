# idb

The Python client for idb (iOS Debug Bridge), a command-line interface and
gRPC service for automating iOS simulators and devices. This folder holds the
client library, CLI, gRPC bindings, and shared utilities; it is exported to the
open-source `facebook/idb` repository alongside `fbobjc/Tools/idb/` and
`xplat/idb/`.

## Notification service extension delivery

`Client.send_notification(bundle_id, json_payload, process_service_extension=True)`
(or `idb notification send BUNDLE JSON --service-extension`) invokes the app's
notification service extension before local delivery. Existing callers can also
opt in with the reserved top-level JSON key `"idb-service-extension": true`:

```json
{"idb-service-extension": true, "aps": {"alert": "Hello", "mutable-content": 1}}
```

The reserved value must be a boolean. The client removes the key before sending
and combines its value with the explicit option using OR, so `false` does not
cancel an explicit opt-in. Requested extension delivery is rejected before the
notification RPC if the companion does not advertise support. Payloads without
the reserved key retain their original bytes, including when the explicit
option is used.
