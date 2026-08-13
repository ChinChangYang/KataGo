# 0005 — Downloads run through one app-wide center, resumed by HTTP Range

Date: 2026-08-13
Status: Accepted

## Context

Two pieces of tester feedback arrived together: opening-book downloads are "too
slow", and the book picker should show the spinning KataGo icon the network
picker shows. The first turned out not to be about bytes.

Measured against the real CDN (24 MiB of the 9×9 book, warm connection):

| path | time | throughput |
|---|---|---|
| `curl`, one stream | 1.40–1.60 s | ~16 MB/s |
| `URLSession` download task | 1.48 s | 16.2 MB/s |
| 8 parallel ranged streams | 1.31–1.63 s | no reliable gain |
| background-configured session | 1.49 s | 16.1 MB/s |

`URLSession` is already as fast as `curl`, more connections buy nothing, and a
background session costs no throughput. So "improve downloading throughputs"
cannot be answered by moving more bytes per second. What was actually slow:

- On iOS, `Downloader` was constructed as per-view `@State` (macOS and visionOS
  already memoize one per file name and guard the start path against it).
  Popping and re-pushing a detail view minted a fresh instance with
  `isDownloading == false`, so the button's guard passed and a **second
  concurrent transfer of the same file** started — both racing `removeItem` +
  `moveItem` onto one destination. Two or three of those split the bandwidth
  and explain "many minutes" exactly. The transfers survive the pop because the
  session is created per download and never invalidated, so it retains its
  delegate — which also leaks a session per download.
- A failed transfer was **completely silent**: progress reset to zero and no
  error was surfaced anywhere. The error object is discarded at the source,
  `Downloader` has no error property, `download(from:)` is `async throws` but
  its body cannot throw, and all five call sites write `try? await`.
  Indistinguishable from nothing having happened, and every restart began again
  from byte zero.
- There was no resume of any kind, no retry, and `waitsForConnectivity` was
  never set. A 240 MB book had to survive one uninterrupted attempt.
- **Nothing was ever verified.** `didFinishDownloadingTo` moves whatever
  arrived onto the destination with no status-code check and no byte-count
  check, and eleven bare `fileExists` predicates then read that file as
  permanently "downloaded". A truncated response, or an error body, becomes a
  dead asset that can only be fixed by deleting it by hand.

A further hazard sets the resume mechanism. GitHub release assets 302 to a
signed URL whose JWT expires in about 30 minutes; `URLSessionDownloadTask`
resume data embeds **that** URL, not the stable `github.com` one. Verified by
capturing a redirect, sleeping past its `exp`, and re-requesting:

```
HTTP/2 618
<title>618 jwt:expired</title>
content-length: 430
content-disposition: attachment; filename=book6x6jp-20230525.kbook.gz
accept-ranges: bytes
```

Resume data would therefore have failed precisely in the case resumability
exists for — an overnight resume. Worse, the delegate never inspects a status
code at all (`URLSession` reports success for 4xx and 5xx just the same), so
this is **already a live corruption path in shipped code**: a fresh download
that catches an expired redirect moves those 430 bytes of XML onto
`book6x6jp-20230525.kbook.gz` and reports it downloaded. 618 is merely the
version of it that no status-range check would have caught either.

## Decision

**One `DownloadCenter`, keyed by destination URL, resuming by HTTP Range
against the stable URL.**

1. `Downloader` is retired. `DownloadCenter` is an app-wide registry vending
   one observable `Download` per destination URL. Keying by destination — not
   by file name — is what makes a duplicate transfer unrepresentable, and the
   background session has to persist that mapping anyway to move a file after
   a relaunch.
2. Transfers run on a **background `URLSession`** with `isDiscretionary =
   false` and `waitsForConnectivity = true`, so a download continues while the
   app is backgrounded and waits out a missing network instead of failing.
   iOS receives the relaunch handoff through `Scene.backgroundTask(.urlSession(matching:))`;
   the app has never had a `UIApplicationDelegate` and does not gain one.
3. **Resume is `Range: bytes=<offset>-` against the catalog URL**, with
   `If-Range: <stored ETag>`. The redirect is re-resolved on every attempt, so
   expiry cannot bite. A resume accepts **exactly 206**; 200 means the asset
   changed, which discards the partial and starts over; anything else is an
   error. The server's `Content-Range` total — not the catalog's `fileSize` —
   is the authority for both progress and verification.
4. **Stop means pause.** Paused keeps its partial and never resumes itself.
   Interrupted keeps its partial and resumes at launch and whenever
   connectivity returns. Every consumer moves off the `isDownloading`
   true→false edge onto an explicit state, because `cancel()` already sets that
   edge and a pause would otherwise read as *completed* on all five surfaces.
5. **Failure is silent but never lossy.** Three retries at 2 s / 8 s / 30 s; on
   exhaustion the download lands **paused with its partial intact**, one tap
   from resuming. No error message is shown.
6. **One transfer at a time**, app-wide; the rest are *waiting*. Since
   parallelism buys nothing, a queue is strictly better: full throughput to one
   file and an honest ETA.
7. **Partials never touch a destination.** They live in a dedicated staging
   directory under Application Support, excluded from backup, swept at startup
   of anything orphaned or older than seven days. A download's bytes reach
   their destination only after **verification** against the server's declared
   total.
8. The rotating icon becomes `DownloadProgressIcon` in `KataGoUICore`, taking
   `icon: Image` un-resized (the `LoadingIcon` asset lives in the four
   app-target catalogs that use it — iOS, macOS, tvOS, visionOS — never in the
   package) and applying the model picker's four modifiers verbatim:
   `.resizable()`, `.scaledToFit()`, `.clipShape(.circle)`,
   `.rotationEffect(.degrees(progress * 360))`. Adopted by iOS models, iOS
   books, and visionOS models; visionOS keeps its `.frame(width: 160, height:
   160)` at the call site, which is the only way its copy ever differed. Paused
   simply stops rotating. Progress must be guarded against a server that
   declares no length, which today yields a NaN rotation angle.

## Alternatives rejected

- **Parallel chunked downloading.** The literal reading of the feedback, and
  measurement says it is worth ~0% on a healthy link while adding a stitcher
  and an ordering hazard. Range resume leaves it cheap to add if a real network
  ever shows otherwise.
- **`URLSessionDownloadTask` resume data.** Far less code, and it pins an
  expiring redirect. Its failure mode is an overnight resume dying on a status
  code that does not look like an error.
- **Catalog `fileSize` as the verification authority.** The catalog's sizes are
  hand-maintained and already drift: `FD3 Network` and `Strong Large Board Net
  M2` both carry a copy-pasted `271_357_345` against live `content-length`s of
  271,365,609 and 271,378,684, so verifying against the catalog would fail every
  download of either one today. (The Official network, whose stable
  `official.bin.gz` name makes it look like the hazard, is currently
  byte-exact — its size is bumped alongside its URL.)
- **Partials beside their destination, or in Caches.** Eleven bare `fileExists`
  predicates decide "downloaded" and not one of them checks a size, so anything
  that ever lands on a destination path reads as downloaded forever; Caches can
  be evicted under storage pressure, silently reintroducing the
  restart-from-zero bug being removed.
- **Keeping macOS's cancel-on-window-close.** Preserves a documented promise
  and makes autonomous resume inert on macOS, which is the platform where the
  process keeps running anyway.
- **Surfacing download errors.** Considered and declined: retries plus a
  preserved partial make the common failure recoverable without a message.

## Consequences

- **Closing the macOS Models or Opening Books window no longer cancels
  transfers** — it detaches observation. Four in-code comments asserting the
  opposite are rewritten (the `ModelsWindowController` file header and its
  `windowWillClose` doc, the `ModelsViewController` file header, and the
  `OpeningBooksWindowController` file header), plus the `cancelAllDownloads()`
  doc. Reopening the window shows live progress.
- Any code reading a downloaded asset must keep treating "complete file at the
  destination" as downloaded, with no sidecar required. The UI suite's offline
  guarantee rests on exactly that, and on `ModelDetailView.downloadPlayButton`
  staying one always-present button across Play / Download / Pause / Resume.
- Auto-resume needs a launch-argument kill switch, or a background session
  would issue unattended network traffic inside a suite whose offline
  guarantee is asserted in a comment.
- Completion side effects move off the views. Activation of a freshly
  downloaded book sits inside `OpeningBookPickerView`'s `.onChange`, so it
  silently does not run once the detail view has been popped; it now always
  runs. The `BinFileHasher` pre-hash does survive a pop — it is a closure on
  the retained `Downloader` — but it is installed at three independent call
  sites and on no book path, and becomes one center-owned hook.
- The center must create the destination directory itself. Both book paths
  call `OpeningBook.ensureBooksDirectory()` from the view immediately before
  downloading, and after a relaunch no view is there to do it — the final move
  is a `try? moveItem` and would fail silently.
- `ModelStagingUITestSupport` compares an existing staged file against catalog
  `fileSize` for exact equality. It is the one place the catalog size stays
  load-bearing, and given the FD3/M2 drift above it is the next thing to rot.
- **Cellular remains unguarded, deliberately.** An 863 MB network over LTE
  still starts without a warning, as it does today.
- Nothing garbage-collected partials before, because none existed. The sweep
  ships with the feature rather than after it.

## Amendment 2026-08-13 — transfers are chunked

Decision 3 described one open-ended `Range: bytes=<offset>-` per attempt.
Implementation showed that loses more than it saves: a `URLSessionDownloadTask`
surrenders its bytes only when it *finishes*, so a dropped connection at 95% of
a 240 MB book discards 228 MB — exactly the case resumability exists for — and
the only Apple-supplied alternative, `cancel(byProducingResumeData:)`, is the
one this ADR rejected for pinning a redirect that expires in about thirty
minutes.

The transport therefore requests fixed **32 MiB** ranged chunks in sequence,
appending each to the partial. Everything decision 3 promised still holds — the
request goes to the stable catalog URL, carries `If-Range`, accepts exactly 206,
and takes its total from `Content-Range`. What changes is the bound on loss: a
drop or a pause now costs at most one chunk instead of the whole attempt. The
price is one extra round trip per 32 MiB — eight for the largest book, under a
tenth of its transfer time on a healthy link.

`CONTEXT.md` needs no new term: a chunk is an implementation detail of a
*transfer*, and the glossary is implementation-free by design.

## Amendment 2026-08-13 — the book-activation consequence was wrong

Consequences said activation of a freshly downloaded book "sits inside
`OpeningBookPickerView`'s `.onChange`, so it silently does not run once the
detail view has been popped; it now always runs." That is false, and
implementation is what exposed it.

`OpeningBookPickerView()` is constructed in exactly one place in the running
app, from `ModelPickerView`, and `ModelPickerView` is shown only when no model
is selected. The opening-book screens therefore exist only *before* a game
session does — never alongside one. `BookLookup` is instantiated inside
`GameSession`. While the picker or its detail view is on screen, there is no
session and so no `BookLookup` to call. The old `.onChange` called
`bookLookup?.loadIfNeeded(...)` on an environment value that was nil in the
only state that screen can be shown in. It was already a no-op — not
something that merely stopped working once the view was popped, because it
never ran while the view was present either. The consequence described a bug
that did not exist, and promised a fix for it that no code could have
delivered.

What actually makes a freshly downloaded book usable is the paths that
already covered it: the session's own `loadIfNeeded` at startup, and the eye
button's availability check, which reads disk state directly. What the
center's `finishedGeneration` hook genuinely adds is coverage for the case
those paths miss — a download that outlives the picker, started there but
finishing once a game is already running. iOS observes it in `ContentView`;
macOS observes it in `MainWindowController`, where it also drives
`refreshBookStateForSelectedGame()` for a book that finishes while the
Opening Books window is closed — a case that could not arise before, because
closing that window used to cancel the download outright.
