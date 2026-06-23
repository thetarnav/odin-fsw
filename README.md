# fsw — Filesystem Watcher for Odin

Cross-platform file and directory watching library.\
Uses native backends where available (inotify on Linux, kqueue on Darwin/FreeBSD/NetBSD/OpenBSD, ReadDirectoryChangesW on Windows),\
with a polling fallback for all platforms.

## Usage

The library is **pull-based**:
constructors create OS handles and prepare internal state but do not start threads.
The user drives the event loop by calling `get_events` on a watcher.

```odin
import fsw "odin-fsw"

// Create a native watcher for a directory
w, err := fsw.watch_dir("/tmp")
assert(err == nil)
defer fsw.destroy(w)

// User-driven event loop. Each get_events call drains the OS queue
// and returns a fresh dynamic array of events
for {
    events := fsw.get_events(&w)
    defer fsw.delete_events(events)

    for event in events {
        fmt.printfln("%v: %s", event.kind, event.path)
    }

    // sleep if you want to avoid a tight loop
    time.sleep(100 * time.Millisecond)
}
```

`get_events` performs one OS read / poll cycle and
returns all events that were available.\
The returned `[]Event` and each `event.path` string are allocated with
the allocator passed to `get_events` (defaults to `context.allocator`).\
Pass `context.temp_allocator` for fire-and-forget use.

```odin
// Fire-and-forget: no cleanup needed, the temp allocator handles it
events := fsw.get_events(&w, context.temp_allocator)
for event in events {
    fmt.printfln("%v: %s", event.kind, event.path)
}
```

Or free manually:

```odin
for event in events {
    delete(event.path)
}
delete(events)
```

## Constructors

All constructors return a stack-allocated value by default.\
Call `destroy(w)` when done.

| Constructor | Type | Backend |
|---|---|---|
| `watch_file(path)` | `Watcher_File` | inotify/kqueue/IOCP |
| `watch_dir(path)` | `Watcher_Dir` | inotify/kqueue/IOCP |
| `watch_dir_recursive(path)` | `Watcher_Recursive` | inotify/kqueue/IOCP |
| `watch_file_poll(path)` | `Watcher_File_Poll` | polling |
| `watch_dir_poll(path)` | `Watcher_Dir_Poll` | polling |
| `watch_dir_poll_recursive(path)` | `Watcher_Recursive_Poll` | polling |
| `watch_glob(pattern)` | `Watcher_Glob` | recursive + filter |

All constructors accept an optional `allocator` parameter (defaults to `context.allocator`).

`get_events(&w)` and `rescan(&w)` take a pointer to the watcher — they read and update
internal state (the `prev` map for poll watchers, the inotify/kqueue watch set for
recursive watchers, etc.).

If you need to store a watcher opaquely without committing to a specific kind,
use the `Watcher` tagged union — `destroy`, `get_events`,
and `rescan` all dispatch on it:

```odin
w: fsw.Watcher
w = fsw.watch_dir("/tmp") or_return
defer fsw.destroy(w)
events := fsw.get_events(&w)
```

### Native watchers

Use the OS-native notification mechanism. Preferred when available.

- `watch_file` — watch a single file for changes.
  (continues to watch after deletion for when the file is added again)
- `watch_dir` — watch a directory (non-recursive, immediate children only).
- `watch_dir_recursive` — watch a directory and all subdirectories.
  New subdirectories are automatically watched.

### Polling watchers

Fallback when latency-based polling is desired.

- `watch_file_poll` — stat-based polling.
  User drives polling by calling `get_events`;
  each call performs one `stat()`.
- `watch_dir_poll` — snapshot-based directory polling.
  Each call does one snapshot diff.
- `watch_dir_poll_recursive` — recursive snapshot-based polling.

User should `time.sleep(latency)` between `get_events` calls.

### Glob watcher

Watches a directory recursively, filtering events through a glob pattern.

```odin
w, err := fsw.watch_glob("/tmp/*.txt")
```

The watcher extracts the static directory prefix as the watch root, then filters events through the pattern.\
Only files matching the pattern trigger events.

## Events

```odin
Event :: struct {
    kind:   Event_Kind,  // Added, Removed, Modified, Renamed, Overflow, Invalidated
    path:   string,      // Absolute path of the affected file/directory
    is_dir: bool,        // True if the target is a directory
}
```

## Rescan

Force a full rescan. Available for recursive and glob watchers:

```odin
// works for Watcher_Recursive, Watcher_Recursive_Poll, Watcher_Glob
err := fsw.rescan(&w)
```

For non-recursive watchers, `rescan` is a no-op.

## Gotchas

### Glob pattern format

`watch_glob` uses `filepath.match` for pattern matching.\
Patterns like `*.txt` match at the top level only.\
Use `**/*.txt` for deeper matching if supported by your platform's `filepath.match`.

### Recursive watcher memory

`watch_dir_recursive` and `watch_glob` allocate a map to track watched subdirectories.\
For very deep directory trees, this uses more memory than flat watchers.

### Rescan after external changes

For Linux and kqueue-based recursive watchers:\
if subdirectories are deleted out from under the watcher,
`rescan` rebuilds the watch set.\
For Windows, `ReadDirectoryChangesW` with `bWatchSubtree=TRUE` tracks subdirectory changes automatically,
so rescan is a no-op.

## Demo CLI

A small CLI lives in `example/main.odin`. It wraps `watch_glob` and prints events to stdout.

```sh
make example # odin run example -- "./*.odin
# or
odin run example -- "/tmp/**/*.log" 200  # 200ms poll interval
```

Quote the glob so your shell does not expand it. Press Ctrl-C to stop.
