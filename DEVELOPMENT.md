# 開発者向けメモ

ユーザー向けの説明・動作環境・セットアップは [README](README.md) を参照

---

## Overview

ClaudeUsageMonitor works as a loop: load → fetch → output → show.

1. **Load**: A WKWebView owned by the app keeps the claude.ai page open, so that the user's login session (cookies) is available to the page's own scripts.
2. **Fetch**: At every tick (the configured interval, a manual update, or right after a page load), a script run inside that page calls claude.ai's usage API from the same origin and hands the raw result back.
3. **Output**: The result is turned into a fixed JSON shape, written to a file and posted to an API endpoint, each only when configured.
4. **Show**: The menu bar icon and the menu show the latest status and usage.

The app is a menu bar app with three SwiftUI scenes (the menu bar extra, the log window, the settings). The main window holding the WebView is not a SwiftUI scene; it is an AppKit window owned by the central manager (AutomationManager), which also owns the WebView, the timer, fetching and the status.

---

## Glossary

- **Plan** — Individual (Pro and Max, not distinguished) or Enterprise, decided from the shape of the usage response.
- **Session / weekly / monthly usage** — For Individual, the 5-hour session window and the 7-day window. For Enterprise, the monthly usage, carried in the session fields of the JSON.
- **Tick** — One round of fetch → output → status update.
- **Output** — The two optional destinations of the JSON: the file and the API endpoint.
- **Normal / Orange / Red** — The three icon states. Orange is Normal with the session or weekly usage at or above the warning threshold; it is derived from the status and the last usage, not stored.

---

## Rules to Keep

### Fetching Usage

- Usage is read from claude.ai's API (the organizations list, then the organization's usage), not scraped from the page's DOM. Only those two endpoints and the response keys used for the plan and the percentages are relied on, so changes to the page's markup do not break fetching.
- The fetch runs inside the page with relative paths, so it is same-origin and uses the page's session without the app handling cookies or hard-coding the host.
- The script never rejects; it always resolves a flat dictionary of raw facts (stage, status, content type, the head of the body). What those facts mean (not logged in, which failure, whether to count it) is decided in one place on the Swift side (classifyAndApplyFetchFailure). Splitting the judgement between the two sides would make the status rules drift.
- Which organization to use is decided in one place in the script (the first one). Supporting multiple organizations means changing only that spot.
- The organization's identifier is cached and cleared when the session may have changed (session clear, not logged in) or the organization is gone (404).
- Each fetch carries a generation number, and its result is applied only if the generation still matches. A reload or cancel moves the generation forward, so a fetch started for the previous page cannot change the status after the reload. A Swift-side watchdog covers the case where the script's completion never arrives (the WebContent process misbehaving).
- Individual is decided by the presence of the 5-hour or 7-day data first; Enterprise only when both are absent and extra usage is enabled. Extra usage is an option Pro and Max users can turn on, so checking it first would misclassify them. A missing value on one side is output as null, not treated as a failure.
- The Enterprise reset time is not in the response; it is taken as the first day of the next month in JST. This is an assumption about the plan.

### Status and Recovery

- Waiting for the first fetch after launch shows the Normal icon; only the menu's status label says it is waiting. The icon turns Red only for an actual problem, so that every launch does not look like a failure.
- Not logged in, a page other than claude.ai, and an empty URL are shown as Red without counting toward consecutive failures. Counting them would trigger the automatic reload over and over while the user simply has not logged in.
- A failed page load (other than one cancelled by a newer navigation) is shown as Red. When the page left behind is not claude.ai (a load at launch or from a manual update, which goes through about:blank), monitoring stops until the user runs a manual update; the following ticks would otherwise relabel it as "a page other than claude.ai", and that label does not replace the load failure. When the previous claude.ai page is left behind (the automatic reload failed), ticks go on fetching from it as usual, so fetch failures keep counting and reloading.
- A navigation cancelled by a newer one is ignored entirely, including the pending second step of a manual update. Pressing manual update again while the first is still loading cancels the first load, and clearing the pending step on that cancellation would leave the page on about:blank.
- Not logged in is detected positively from the fetch response (401/403, or a 200 that is not JSON, which is a login page served after a redirect), not inferred from navigation alone.
- Fetch failures count, and after a set number in a row the page is reloaded. The reload is skipped while an OAuth popup is open, because reloading breaks the sign-in flow.
- Failures on the output side (writing the file, posting to the API) are shown as their own Red state and do not count. The fetch itself succeeded, so a reload cannot fix them and would only repeat; the failure count goes back to zero instead. The icon stays Red so that the user notices the output is not being updated.
- The file write and the post run independently, and their results are combined into exactly one status update per tick. When both fail, the file side is shown.
- A login/logout redirect loop is detected by a small state machine over navigations (login → logout → login → logout within a short time window), and clears the session. Other URLs (about:blank, subdomains, the usage page) are ignored rather than resetting the machine, because the intermediate URLs of a normal flow would otherwise break the count. The time window separates a real sign-in (seconds, with user input) from a loop (fast).
- The post is retried once when it fails with "not connected to the internet" right after launch: URLSession can report that before it notices the network, even though the machine is online.

### Output

- The JSON keys are sorted and every field is always present, with null for missing values, so readers can rely on a fixed shape. All times are JST regardless of the machine's time zone, written in ISO 8601 with the UTC offset, so a reader (for example an agent deciding how long to wait for a reset) gets the right instant whatever time zone it runs in. Reset times are rounded to the nearest ten minutes in JST.
- The file name is reduced to its last path component before use, so a name like `../../x` cannot write outside the output folder.
- The output folder is either the temporary directory or a folder the user picked. It is stored as a plain path: the app runs without App Sandbox, so no security-scoped bookmark is needed. The folder can only be picked in the open panel, not typed, to avoid typos.
- Saving the settings with a changed output folder or file name writes and deletes a hidden probe file in the picked folder. This brings up the macOS privacy prompt (Desktop, Documents and so on) while the user is at the screen, instead of during a background tick. A separate name is used because writing to the real file name would replace the existing JSON with an empty one until the next fetch.

### Timer and Settings

- The timer belongs to the manager, not to a view, so it runs even if no window has ever been opened. Settings changes reach it through Combine subscriptions for the same reason.
- Subscriptions to settings put removeDuplicates before dropFirst. In the other order, removeDuplicates has no previous value after the first is dropped, so the first save of an unchanged value fires and restarts the timer for nothing.
- A subscriber never reads the setting's property directly: @Published fires before the property is written, so it would read the old value. It hops to the next run loop turn and reads the property there.
- Every tick restarts the timer, whichever path started it. Without this, a manual update or a post-load fetch could be followed immediately by the timer's own tick.
- A manual update fully reloads the page through about:blank. Fetching itself does not need the page, but the reload makes a logged-out session show up as a redirect to the login page.
- The first load is delayed a few seconds after launch, because as a login item the network is often not up yet. It goes through the same path as a manual update, so there is one load path.
- A page load is followed by one fetch after a short delay; repeated loads during sign-in collapse into a single fetch.
- The settings window edits a buffer. Settings are written only on Save, so the timer restarts and the page reloads at most once per save, not on every keystroke. Cancel puts the buffer back to the saved values. A new setting needs its own buffer entry; binding a field directly to the settings would bypass Save and Cancel.
- Save is disabled while "any folder" is selected without a folder. Switching back to the temporary directory keeps the picked folder, so switching again restores it.
- Launch at login and the session clear act immediately and are placed below Save and Cancel to show they are not part of the buffer. Destructive operations such as the session clear live in the settings, not the menu, to avoid mis-clicks.

### Windows and the WebView

- The WebView lives in an AppKit window owned by the manager, kept invisible but on screen (fully transparent, ignoring the mouse). A WebView in a SwiftUI window whose launch is suppressed never joins the view hierarchy, and macOS throttles its rendering and scripts; hiding it by ordering out, minimizing or moving it off screen is throttled the same way or clamped back on screen. Closing the window is intercepted and turned into making it transparent again.
- Windows created in code set isReleasedWhenClosed to false. With the default, closing sends an extra release while Swift still holds the window, and the next access crashes.
- The WebView must return a popup WebView when the page asks for one. The system's sign-in coordinator always requests a popup during OAuth, and returning nil freezes the UI.
- The log window can stay a SwiftUI scene with suppressed launch, because it holds no WebView.
- The log text is drawn with an NSTextView, not a SwiftUI Text with selection enabled. With the log at its full size, Text recomputes hit testing and glyph geometry on every hover and scroll and keeps the CPU at 100%. The same applies to any large selectable text added later.
- Log calls hop to the main queue asynchronously instead of assuming main-actor isolation, which crashes when called off main.

### Menu Bar Icon

- The icon is an image drawn in code from a silhouette asset. Normal is a template image so it follows the menu bar's appearance; Orange and Red are filled with a fixed color through the silhouette. A colored SF Symbol does not work here: the menu bar extra turns it into a monochrome template whatever rendering mode is set.
- The menu bar extra is used instead of NSStatusItem with an app delegate, so the menu binds directly to the manager's published state.

### Notifications

- A notification is sent only on the transition into Orange, and not again until the icon leaves Orange. Each notification gets a unique identifier so that one transition never replaces the notice of another.
- There is no switch for notifications in the app; macOS's notification settings are the only place to turn them on or off. A denied permission only silences notifications; monitoring continues.

### Launch at Login

- The system (SMAppService) holds the truth; the settings window reads it each time it appears. After a failed register or unregister, the shown state is read back from the system instead of assuming the request took effect. When registration needs approval, the state stays off and the system settings are opened.

### Build Settings

- The default actor isolation build setting must stay off. With it on, every class becomes main-actor isolated, and releasing an object from a background thread when returning from OAuth crashes the app.
- The app has no Info.plist file; the menu-bar-only flag (LSUIElement) is set in the build settings of both configurations.

---

## Build and Test

`make build` builds the Release configuration into build/, and `make install` copies it to /Applications. The project file is kept in the repository and is not generated (no XcodeGen). `make uninstall-all` also removes the WebView data (the login session), the container macOS may create for the settings, and the defaults; the bundle ID is read from the project file. When checking a newly added setting, start from this clean state: macOS can keep a second copy of the defaults in the container, so deleting the defaults alone does not reset them.

There are no automated tests. Behavior is checked by hand on the installed app:

- With no window ever opened, ticks keep succeeding, and from the second tick on the organization is not resolved again.
- Closing the main window and waiting for the next tick still succeeds; reopening keeps the size and centers the window.
- After a session clear, the organization is resolved again and the status turns to not logged in, without counting failures or reloading; after signing in it recovers on its own.
- Settings take effect only on Save; saving an unchanged interval does not restart the timer; an empty URL turns the WebView blank and the status Red.
- With the output folder set to a picked folder, saving brings up any privacy prompt at once and the next tick writes the JSON there. An unwritable folder shows the output failure state without reloading the page.
- Repeated fetch failures (network off) reload the page; results of a fetch started before a reload are not applied.

Development switches are written in the source and must be put back before distributing: the log's minimum level (LogStore) can be lowered to debug to trace ticks, fetch details and plan decisions, and the Enterprise test mode (AutomationManager) classifies an Individual response as Enterprise when extra usage is enabled, to check the Enterprise display and JSON with a Pro or Max account.

---

## Known Constraints

The app is signed ad hoc and runs without App Sandbox. Registering the login item may need approval in the system settings, and that cannot be avoided without a Developer ID signature and notarization.

Fetching depends on claude.ai's API paths and response shape; a change on their side stops it.

The post uses the shared URLSession without certificate pinning or authentication headers, so the endpoint is assumed to be in a trusted environment.

The WebView's processes log many sandbox-related warnings (pasteboard, launch services, network); they are harmless.
