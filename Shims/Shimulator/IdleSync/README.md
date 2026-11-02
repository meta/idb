# Idle synchronization

The `idle` capability reports when a process in the simulator is idle: its main
run loop has no work to do, no animation is running, nothing is scrolling and no
main-thread work is due shortly. It is computed inside the process, from load,
by the trackers below.

It is armed by `IDB_IDLE_SYNC=1` in the process's launch environment. Without
it, nothing in this directory tracks anything; only the interposed
`dispatch_after` wrappers run, and they forward at once. A process launched with `idb launch` gets it
from `IDB_IDB_IDLE_SYNC=1` in the client's environment, which strips one `IDB_`
prefix.

## What counts as busy

| Source | How it is observed | Ignored |
|---|---|---|
| Main thread work | A run loop observer times each wake | A wake shorter than the busy threshold, 8 ms unless the host sets another (timers, display link ticks) |
| Animations | `-[CALayer addAnimation:forKey:]`; the end time is scaled by the layer's effective speed | Longer than 2 s, repeating forever (spinners, loops), or on a paused layer (speed 0) |
| Scrolling | `-[UIScrollView setContentOffset:]` changing the offset of a scroll view in a window, which every scroll goes through: drags, deceleration and programmatic scrolls | — |
| Delayed work | `dispatch_after` / `dispatch_after_f` on the main queue (interposed), `performSelector:afterDelay:` and one-shot `scheduledTimer…` on the main thread: busy until it is due, plus the tenth of its delay a timer may fire late | Due more than 1.5 s ahead, or scheduled more than 3 times in 5 s from one call site with the same work (a loop), until that site has been quiet for 5 s |

A host that reads the UI through the accessibility label of one of the app's
own classes names that class in `IDB_IDLE_SYNC_HOST_READ_CLASS`. Time the main
thread spends building that label is not counted as work, so the host's own
reads do not make the process look busy.

The process is idle once none of these has held for 100 ms. It is busy from load
until its main run loop first goes to sleep.

## Protocol

The `idle` capability of the Shimulator protocol (`Protocol/`,
`IdleSyncProtocol.swift`). The host serves
`/tmp/idb-shimulator-<uid>/<UDID>.idle.sock` and sends each process that
connects `{"version":1,"parameters":{"busyThresholdMs":<ms>}}`, where
`busyThresholdMs` is optional. The process reports `accepted` whenever its state
changes, with the state as the response's `payload`:

```json
{"idleSince":1793132055432,"reasons":[]}
{"reasons":["main","animation"]}
```

`idleSince` is the wall-clock time in milliseconds, which a simulator process
shares with its host, when the current idle period began; it is absent while
the process is busy. `reasons` names what keeps it busy (`main`, `animation`,
`scroll`, `delayed`), and a host skips a reason it does not know.
`lastInputAt` is when the process last finished handling the end of a touch
sequence or a key press (`-[UIApplication sendEvent:]` with every touch or press
ended or cancelled), absent until it has handled one; it does not
make the process busy. A host that keeps the latest state
therefore knows whether the process has stayed idle since any moment it cares
about. The trackers run from load, so a host that connects to a process that
has been idle for a while hears when that idle period began. After a host
changes the busy threshold, work the new one counts may have gone unrecorded,
so no idle period is dated before the process's first report under it.

The process connects when it loads, and again whenever the socket reappears,
so a host that starts later still hears from every armed process. Disconnecting
restores the default busy threshold; the trackers keep running.

The companion serves it for `accessibility_quiescence` with the `SHIMULATOR`
backend (`//xplat/idb:idb.proto`, and `SimulatorIdleSyncCommands` in
`FBSimulatorAX`).

## Cost

A process launched without `IDB_IDLE_SYNC=1` pays one forwarding call per
`dispatch_after`. An armed process pays for one run loop observer, the swizzles
above, and a thread that samples the trackers every 10 ms while a host is
connected.
