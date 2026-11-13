# FBSimulatorServices

Changes state inside a booted iOS Simulator that no `simctl` verb reaches, by running idb's `SimulatorFrameworkBridge` helper inside it. It is added onto `Simulator` from outside [`FBSimulatorControl`](../FBSimulatorControl/README.md): a consumer that uses none of it neither links it nor ships the helper.

It adds these commands to `Simulator`:

| Command | What it does |
| --- | --- |
| `contacts` | Replaces the contacts database from a file, or clears it |
| `photos` | Clears the photo library |
| `health` | Grants, revokes, lists and clears an application's HealthKit authorizations |
| `notification` | Sends a push notification, and lists and clears an application's delivered notifications |
| `privacy` | Grants and revokes privacy permissions (TCC), including location, and approvals for URL schemes |
| `network` | Sets, lists and clears the proxy and DNS configuration |
| `preferences` | Applies settings (`SimulatorSetting`): appearance, Dynamic Type, accessibility, keyboard, and raw preferences |
| `orientation` | Reads and sets the physical device orientation, confirming that a change took effect |
| `lockScreen` | Reads SpringBoard's lock state, and locks and unlocks the device through SpringBoard rather than the lock button's toggle; an unlock presses the Home button, which SpringBoard honours on every runtime, before the helper confirms it |

Each of these runs some or all of its work in the helper; the rest writes the Simulator's data directory or its defaults directly, and writing an orientation, and the Home button press of an unlock, go through the Simulator's HID services. The helper is staged and spawned on demand and talks to the host over a Unix domain socket. The connection is held per Simulator and reused, so a warm call does not pay to start the helper again. [`FBSimulatorAX`](../FBSimulatorAX/README.md) reads accessibility through the same helper, and [`FBSimulatorCodeInjection`](../FBSimulatorCodeInjection/README.md) starts the Simulator-wide REPL through it.

### URL scheme approvals

Approving a URL scheme for an app records it in the `com.apple.launchservices.schemeapproval` preferences domain, which `lsd` reads to decide whether to open a URL without asking "Open in “App”?" first. `lsd` keeps that domain cached in process and drops its copy only when the Simulator's preferences daemon reports a change, so on a booted Simulator approvals and revocations are written through the daemon with the runtime's `defaults` tool; a plist rewritten underneath it goes unseen. A shut-down Simulator has nothing cached, so its plist is written directly. Other states are refused. A revocation is confirmed by reading the key back. Approving a scheme does not choose which app opens it: when several installed apps claim the scheme, LaunchServices picks one, and if that is not the approved app it asks anyway.

### Notification service extensions

`simulator.notification.sendPush(forBundleID:jsonPayload:processServiceExtension:)` keeps ordinary simulated push delivery unchanged when `processServiceExtension` is false. With it true, the companion launches a oneshot guest, which discovers the installed app's notification service extension and invokes it through Apple's extension host. The request must have alert text and `aps.mutable-content: 1`. The guest delivers the returned content, or honours suppression; a missing extension, runtime error or timeout fails the call without posting the original payload. This works with the main app terminated and requires neither an APNs token nor a SpringBoard restart. The guest ends with the caller, and the command is never replayed after an uncertain delivery. Expiry and insertion initiation are serialized: if expiry wins, insertion is never started; if insertion was already started but no acknowledgement arrives, the timeout reports an unknown delivery outcome. Cleanup errors are logged without changing a confirmed insertion result.

## Resources

The helper, `SimulatorFrameworkBridge-iOS` (and `-tvOS` for tvOS Simulators), is a resource of this library. It is a Simulator binary signed for the Simulator, and must be shipped as it is, without re-signing. Point `BundledResources.hostDirectoryPath` at the directory you copy it to, as described in [FBSimulatorControl's resources section](../FBSimulatorControl/README.md#resources). Contacts, Health and delivered notifications are not available on tvOS, whose SDK lacks those frameworks, and the lock screen is not available on tvOS or watchOS, which have no SpringBoard.
