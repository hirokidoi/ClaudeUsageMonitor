# 開発者向けメモ

ユーザー向けの説明・動作環境・セットアップは [README](README.md) を参照

---

## Overview

ClaudeUsageMonitor works as a loop: run the CLI → read the cache → output → show.

1. **Run the CLI**: At every tick (the configured interval or a manual update), the app runs Claude Code CLI's `/usage` command as a child process. The command does not call the model; it makes the CLI refresh its own usage cache.
2. **Read the cache**: The app reads the CLI's cache in `.claude.json` (the usage values and the time they were fetched) and decides whether the tick succeeded.
3. **Output**: The values are turned into a fixed JSON shape, written to a file and posted to an API endpoint, each only when configured and only when the fetch time is new for that destination.
4. **Show**: The menu bar icon and the menu show the latest status and usage.

The logic that does not need the UI or the OS (building the child process, running it with a timeout, reading and parsing the cache, deciding the plan and the JSON, counting successes and failures, deciding whether to output, resolving the status) lives in the Swift package under `Core/`, which is tested with `make test`. The app target links that package and owns the rest: settings storage, the timer, the order of a tick, performing the output (file write and POST), notifications, the menu and the windows.

The app is a menu bar app. The menu bar extra and the log window are SwiftUI scenes. The settings window and the About window are AppKit window controllers owned by AppWindows, which also applies the appearance. The central manager (AutomationManager) owns the timer, ticks, output, the status and notifications.

---

## Glossary

- **Plan** — Individual (Pro and Max, not distinguished) or Enterprise, decided from the organization type recorded in the cache.
- **Session / weekly / monthly usage** — For Individual, the 5-hour session window and the 7-day window. For Enterprise, the monthly usage, carried in the session fields of the JSON.
- **Tick** — One round of run the CLI → read the cache → output → status update.
- **Cache** — The CLI's usage cache inside `.claude.json`. Its fetch time (`fetchedAtMs`) is the only thing that decides success.
- **Baseline** — The fetch time last seen at a given `.claude.json` location, which the next read is compared with.
- **Output** — The two optional destinations of the JSON: the file and the API endpoint.
- **Normal / Orange / Red** — The three icon states. Orange is Normal with the session or weekly usage at or above the warning threshold; it is derived from the status and the last usage, not stored.

---

## Rules to Keep

### Fetching Usage

- Usage comes from running the CLI's `/usage` and reading the cache it leaves, not from the model. The command is local to the CLI, so a fetch costs no subscription usage.
- Each part of the fetch command prevents a specific side effect: the telemetry variable stops usage statistics from being sent, the session-persistence flag stops it from recording a session, the empty settings-source flag keeps the user's own CLI settings out of a background run, the strict MCP, no-tools, no-browser and safe-mode flags keep the run minimal, and the budget cap is insurance against an unexpected model call. Changing the command means rechecking each of these.
- `--bare` and the environment variable that disables non-essential traffic are not used: both stop the usage fetch itself. Telemetry is turned off with its own variable instead.
- The child process environment is built from an allowlist, not inherited. The app's launch environment can carry an API key or an OAuth token, and the CLI would then authenticate with it and report usage that is not the subscription's. The config directory variable is passed only when the user set one, and not for the version query.
- A configured config directory that does not exist is a failure without starting the CLI: the CLI creates a missing folder.
- The CLI path and the config directory share one rule: a leading `~/` is expanded, and a value that is not absolute afterwards (relative, or a bare `~`) or that has a `.` or `..` component is invalid. Resolving `..` is left to neither the app nor the OS: an existence check lets the OS resolve it and answer "exists", while the CLI keys its login by the path string, so the two would disagree about which folder is meant.
- An invalid config directory is never folded into "not set": that would silently run the CLI against the default folder. The resolution result has three cases (not set, invalid, a path), and the invalid case is checked before existence and stops the run with its own failure. An invalid CLI path is treated as "not found" by the background fetch and shown as invalid in the settings and the connection test.
- The config directory keeps the spelling the user typed: after the rule above the app only removes a trailing slash, and never follows symlinks or standardizes the URL (which would also collapse repeated slashes and drop a leading `/private`). The CLI keys its login by the path string and does not follow symlinks either, so a different spelling of the same folder looks logged out. The folder put at the head of the child's PATH is spelled the same way.
- The CLI rewrites the cache as a whole, so a file that looks broken is read again after a short wait before it is called unreadable. A missing file is not retried. A cache without the account or the usage section is "not logged in", which is valid JSON and is not retried either.
- The cache is the CLI's internal format. Only the account, the usage section and the fetch time are required; every other field is read leniently, and a null, a missing key or a wrong type makes that field nil, never a failure. Integers such as 0 and 100 must be read through NSNumber, because a plain cast to Double drops them.
- The child process runs on a background queue and never on the main thread. The command is run through a timeout that stops it and also bounds the wait for its pipes.

### Success and Failure

- A tick succeeds only if the cache's fetch time differs from the one last seen. The app does not know how often the CLI really refreshes (the CLI throttles), so it never encodes a throttle length; the user matches the interval and the failure tolerance to the CLI's behavior.
- Failures are counted in a row, and the warning (Red and a notification) starts when the count reaches the tolerance. Every place that asks "is this a warning" goes through one function, so the icon, the notification and the status text cannot disagree.
- The baseline is tied to the `.claude.json` location. A baseline is read just before the command only when there is none or the location changed, so a changed config directory is never compared with the old location's value. When no baseline exists after that, a readable cache counts as a success: it only happens when the file was missing or broken, and a file the CLI creates for the first time must not look like a failure.
- A command failure (cannot start, timeout, non-zero exit) counts as a failure and the cache is not read; the baseline is left as it was.
- An expired login is not detected from the command's output. It shows up as the fetch time not changing, and the guidance to log in again is attached only to the reasons that logging in can fix (not updated, not logged in, abnormal exit). Attaching it to others (CLI not found, missing folder) would send the user in the wrong direction.
- A manual update counts like any tick, and an update while a fetch is running is skipped.

### Plan

- The plan is decided by the organization type. Pro and Max are Individual even when extra usage is enabled or the 5-hour data is empty. For other or missing types, Individual is chosen if the 5-hour or 7-day data exists; Enterprise only when both are absent and extra usage is enabled. The 5-hour data being empty alone never means Enterprise, because it is also empty before the first fetch. Extra usage is an option Pro and Max users can turn on, so it must not be checked first.
- A plan that cannot be decided is not a failure: a tick that read a new value is a success under the rule above, so an undecidable plan outputs all-null fields as Individual.
- The Enterprise reset time is not in the cache; it is taken as the first day of the month after the fetch time (not after the current time), in JST. This is an assumption about the plan, and it keeps an old value tied to its own month.

### Status and Notifications

- Waiting for the first fetch after launch shows the Normal icon; only the menu's status label says it is waiting. The icon turns Red only for an actual problem, so that every launch does not look like a failure.
- Red happens in only two cases: the fetch failures reached the tolerance, and an output failure remains. Fetch failures below the tolerance show their progress in the status text and keep the icon decided from the last values.
- The status is decided in one place with a fixed priority, in this order: (1) fetch failures at the tolerance, (2) an output failure that remains, (3) fetch failures below the tolerance, (4) success. An output failure is checked before the below-tolerance fetch failure because, while the destination keeps failing, a tick whose fetch failure has not yet reached the tolerance would otherwise show Normal, and the icon would alternate between Red and Normal and hide the problem. A fetch warning is checked first because the fetch is the app's main job and the log carries the output failure anyway. The fetch failure count keeps running while an output failure is shown; an output failure never resets it.
- "An output failure remains" is kept per destination: the latest attempt failed and there has been no success for the same destination since. It clears on a success, and when the destination key changes, including becoming unset. The current destination key is handed over at every tick, so it also clears on a tick that made no attempt. A tick that made no attempt (for example a command failure) keeps the remaining failure, so the status does not flip depending on whether an attempt happened. When both destinations remain, the file side is shown. The probe of the output folder reports a failure into the same record.
- The status is updated exactly once per tick.
- There are two notifications, each sent only at the moment of the transition: into Orange, and into the fetch warning. Orange tracks the previous icon color and the warning tracks the previous warning state, separately. Each notification gets a unique identifier so that one transition never replaces the notice of another. When nothing has ever been fetched, the warning notification says so instead of giving a last-fetched time.
- There is no switch for notifications in the app; macOS's notification settings are the only place to turn them on or off. A denied permission only silences notifications; monitoring continues.
- Whether a window's reset time has passed is judged only in the menu, from the unrounded reset time, so a value whose reset is up to a few minutes away is not hidden early by the display rounding. The JSON and the Orange judgement use the values as read: judging by elapsed time would need another timer and would change the meaning of a warning that was already issued.

### Output

- The JSON keys are sorted and every field is always present, with null for missing values, so readers can rely on a fixed shape. All times are JST regardless of the machine's time zone, written in ISO 8601 with the UTC offset, so a reader (for example an agent deciding how long to wait for a reset) gets the right instant whatever time zone it runs in. Reset times are rounded to the nearest ten minutes in JST.
- `fetched_at` is the cache's fetch time, truncated to seconds, not the time the app checked. A reader decides whether a value is stale from it.
- Each destination records the destination key and the fetch time last output, and skips output when both match. The file's key is the full path, the POST's key is the endpoint string, so a new destination gets the current value at once, even while fetching is failing. Only a successful output is recorded; a failed one is output again on the next tick, which stands in for a retry. The record is kept in memory only: the first tick after a restart rewrites the same value once, which is accepted rather than comparing against file contents.
- The file name is reduced to its last path component before use, so a name like `../../x` cannot write outside the output folder.
- The output folder is either the temporary directory or a folder the user picked. It is stored as a plain path: the app runs without App Sandbox, so no security-scoped bookmark is needed. The folder can only be picked in the open panel, not typed, to avoid typos.
- Choosing the destination type, picking a folder, or committing the file name writes and deletes a hidden probe file in the picked folder. This brings up the macOS privacy prompt (Desktop, Documents and so on) while the user is at the screen, instead of during a background tick. A separate name is used because writing to the real file name would replace the existing JSON with an empty one until the next fetch.
- The post is retried once when it fails with "not connected to the internet" right after launch: URLSession can report that before it notices the network, even though the machine is online.

### Timer and Settings

- The timer belongs to the manager, not to a view, so it runs even if no window has ever been opened. Settings changes reach it through Combine subscriptions for the same reason. Settings take effect immediately; there is no Save step.
- Fields that a tick reads and that would do something wrong with a half-typed value are not written while they are typed: the interval, the file name, the endpoint URL, the CLI path and the config directory. The draft is held in the view and committed when the user is done with the field, and before anything acts on it. The config directory matters most: while the user types a path, an intermediate value can already be an existing folder (typing `~/.claude_config` passes through `~/.claude`), and a tick at that moment would run the CLI in that folder and let it write `.claude.json` and other files there. The interval would restart the timer on every key, and the file name and URL would create a file or send a request with a partial value. Committing on disappear is required because losing focus is not always delivered when the window closes.
- When a value is chosen with a panel (the CLI path), the field's draft is set to the same value as the committed setting. Otherwise, with focus still in the field, a stale draft would be committed later and overwrite the chosen value.
- Subscriptions to settings put removeDuplicates before dropFirst. In the other order, removeDuplicates has no previous value after the first is dropped, so the first change of an unchanged value fires and restarts the timer for nothing.
- A subscriber never reads the setting's property directly: @Published fires before the property is written, so it would read the old value. It hops to the next run loop turn and reads the property there.
- Every tick restarts the timer, whichever path started it. Without this, a manual update could be followed immediately by the timer's own tick.
- A tick is skipped while a fetch is running, so a slow command never stacks ticks.
- Automatic refresh runs only when the menu's auto-refresh toggle is on and the interval is above 0. Otherwise there is no timer and no fetch right after launch; only manual updates fetch. The toggle is remembered across launches and is hidden from the menu while the interval is 0, so the interval alone decides in that case. Turning the toggle on fetches at once only when the last attempt (automatic or manual, successful or not) is at least the current interval ago; otherwise the timer's first tick is set to the moment one interval after the last attempt. Fetching on every switch would count each refused refetch as a failure, so toggling quickly would reach the tolerance. The last attempt is kept in memory only and is not carried over from the previous launch. The timer is started even if a fetch is skipped because another one is running.
- The first fetch is delayed a few seconds after launch, because as a login item the network is often not up yet. It runs a normal tick. Whether to run it is checked again when it fires, not only when it is scheduled: within those seconds the user may have turned auto refresh off, or turned it back on and fetched already, and fetching again would count a refused refetch as a failure. The same rule as turning the toggle on decides it.
- Setting values read from storage are clamped to their allowed range, and the defaults and ranges live in one place that the screens also use.

### Windows

- The settings window is built with NSToolbar and an NSHostingView whose height follows the content. NSTabViewController is not used: when the content height changes, the view layout drifts from the actual window.
- Windows created in code set isReleasedWhenClosed to false. With the default, closing sends an extra release while Swift still holds the window, and the next access crashes.
- The app is a menu-bar-only app, so a window must activate the app explicitly to come to the front. Activation can be refused while another app is in use, so the settings, About and log windows are also ordered front regardless; otherwise they open behind the app the user is working in. The log window is a SwiftUI scene and may not exist yet right after it is opened, so it is looked up by its title on the next turn of the main queue; the scene and the lookup share one title constant. `activate(ignoringOtherApps:)` is not used: it is deprecated.
- The log window can stay a SwiftUI scene with suppressed launch.
- The log text is drawn with an NSTextView, not a SwiftUI Text with selection enabled. With the log at its full size, Text recomputes hit testing and glyph geometry on every hover and scroll and keeps the CPU at 100%. The same applies to any large selectable text added later.
- Log calls hop to the main queue asynchronously instead of assuming main-actor isolation, which crashes when called off main.
- The appearance setting is applied through NSApp.appearance, from the value delivered by the subscription (not read from the property). It affects the settings, About and log windows but not the menu bar icon or the menu, which follow the OS appearance. The first application is moved to the main queue so it does not run in the middle of app launch.

### Menu Bar Icon

- The icon is an image drawn in code from a silhouette asset. Normal is a template image so it follows the menu bar's appearance; Orange and Red are filled with a fixed color through the silhouette. A colored SF Symbol does not work here: the menu bar extra turns it into a monochrome template whatever rendering mode is set.
- The menu bar extra is used instead of NSStatusItem with an app delegate, so the menu binds directly to the manager's published state.

### Connection Test

- The test calls the model once, only when the user presses the button. It is never called from a tick and its result is never used to judge a tick: the tick's success is decided only by the fetch time. A test may refresh the cache, and that counts as an actual fetch.
- The cheapest model is used with an effort kept low, and no budget cap is set because the CLI's own instructions can exceed a small cap. `auth status` is not used: it only looks at local credentials and cannot tell an expired login.
- The result is interpreted in one place: success needs a zero exit code, no error flag and a string result; authentication wording or an unauthorized status is shown as an invalid login; usage-limit wording is shown as a limit; anything else shows the detail.
- Pressing the button first commits the CLI path and the config directory being typed, because a button does not take focus away from a field. An invalid or missing CLI, and an invalid or missing config directory, each end the test with their own wording without starting the CLI (validity is checked before existence); only when all are usable is the model called.
- When the CLI path or the config directory is committed with a different value, the shown result is cleared and a result still in flight is discarded, counted by a run number. The clearing happens in the commit itself: watching the setting for changes afterwards would also discard the test started right after the commit.

### Launch at Login

- The system (SMAppService) holds the truth; the settings window reads it each time it appears. After a failed register or unregister, the shown state is read back from the system instead of assuming the request took effect. When registration needs approval, the state stays off and the system settings are opened.

### Build Settings

- The default actor isolation build setting must stay off. The manager runs the fetch on a background queue and receives the URLSession completion off the main thread. With main-actor as the default, those closures would be treated as main-actor closures, and running them on another thread crashes. (The child process handling lives in the Core package, which this setting does not reach.)
- The app has no Info.plist file; the menu-bar-only flag (LSUIElement) is set in the build settings of both configurations.
- The Core package targets the same macOS version as the app. A lower floor would make an API usable in the app fail only under test with an availability error.

---

## Build and Test

`make build` builds the Release configuration into build/, and `make install` copies it to /Applications. The project file is kept in the repository and is not generated (no XcodeGen); it refers to the Core package as a local package. `make test` runs the Core package's automated tests; they run the real child process against a fake `claude` script, and they never touch UserDefaults or start the app. `make uninstall-all` also removes the browser data left by versions that fetched through a WebView, the container macOS may create for the settings, and the defaults; the bundle ID is read from the project file. When checking a newly added setting, start from this clean state: macOS can keep a second copy of the defaults in the container, so deleting the defaults alone does not reset them.

When the fetch command changes, check that it still does not call the model: with `--debug-file` the log has no `[API REQUEST] /v1/messages` line, and with `--output-format json` the cost and token counts are zero. Usage statistics do not appear in the debug log; check them through a proxy, where the only requests should be the bootstrap, the mode check and the usage endpoint.

Behavior that only the installed app shows is checked by hand:

- A few seconds after launch the first fetch happens, the menu shows the summary and the last fetch time, and the status turns to normal. The JSON appears at the configured place with the expected shape.
- The CLI does not refetch for a certain period after its last fetch and keeps showing the cached value. A manual update right after a successful one shows a not-updated failure with the icon unchanged; at the tolerance the icon turns Red, one notification is sent and the login guidance appears; a manual update after that period brings it back.
- While the fetch time stays the same, the file's modification time does not change. Renaming the file writes the current value to the new file even while fetching fails.
- A broken CLI path, an invalid CLI path or config directory (relative, or with `..`), a config directory that does not exist, and one without `.claude.json` each show their own wording, and the Claude tab's displays and the test result are cleared. The display rows (path, version, warnings) keep their height.
- The connection test calls the model when pressed, and ticks do not (checked in the CLI's cost display).
- Switching the appearance changes the settings, log and About windows, and the menu bar icon and the menu stay in the OS appearance.
- Each settings tab fits its content height. The interval does not restart the timer while typing and applies on Enter or on losing focus, also when the window is closed (check the log).
- Picking a folder in the output tab shows the privacy prompt at once.
- With the auto-refresh toggle off, or with an interval of 0 (the toggle then disappears from the menu), no automatic fetch happens, also not right after launch; a manual update fetches, and its failure is counted. Turning the toggle on fetches at once only when the last fetch is at least one interval ago; toggling it off and on quickly does not fetch, and the next fetch comes one interval after the last one.
- After the session's reset time passes, the menu shows the usage as unknown and marks the reset line as elapsed.
- About shows the icon, the name, the version and the license.
- Launch at login, including the approval-pending case.

The only development switch is the log's minimum level (LogStore): it can be lowered to debug to trace ticks and fetch details, and must be put back before distributing.

---

## Cache Format

The app reads the following from `.claude.json` (`<config directory>/.claude.json` when a config directory is set, `~/.claude.json` otherwise). This is the CLI's internal format, observed on real Pro and Max accounts; the Enterprise shape comes from a user report and has not been checked on a real account.

| Key | Meaning |
|---|---|
| `oauthAccount` | Present once an account has logged in. Its absence means not logged in. It stays after the login expires. |
| `oauthAccount.organizationType` | The plan. `claude_pro`, `claude_max` and `claude_enterprise` have been seen; other values (Team and so on) are unknown. |
| `cachedUsageUtilization.fetchedAtMs` | When the CLI last fetched usage, in epoch milliseconds. It does not advance while the login is expired. |
| `cachedUsageUtilization.utilization.five_hour` / `.seven_day` | `utilization` (percent) and `resets_at` (UTC ISO 8601, with or without fractional seconds). Any of these, or the whole window, can be null. An old cache keeps a `resets_at` that has already passed. |
| `cachedUsageUtilization.utilization.extra_usage` | `is_enabled` and `utilization` (percent of the monthly limit). On Enterprise, `five_hour` and `seven_day` are null and this carries the monthly usage. |

With a long-lived token instead of a login session, the CLI writes neither `oauthAccount` nor `cachedUsageUtilization`, so only the login session is supported.

---

## Known Constraints

The app is signed ad hoc and runs without App Sandbox. Registering the login item may need approval in the system settings, and that cannot be avoided without a Developer ID signature and notarization.

Fetching depends on the behavior of the CLI's `/usage` command and on the structure of its cache, which are internal to the CLI; a change on its side can stop fetching or make it read as not logged in. Only the account, the usage section and the fetch time are required for that reason.

The post uses the shared URLSession without certificate pinning or authentication headers, so the endpoint is assumed to be in a trusted environment.
