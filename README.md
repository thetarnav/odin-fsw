# fsw — Filesystem Watcher for Odin

Cross-platform file and directory watching library. Uses native backends where available (inotify on Linux, kqueue on Darwin/FreeBSD/NetBSD/OpenBSD, ReadDirectoryChangesW on Windows) with a polling fallback for all platforms.

## Pull-Based API

The library is **pull-based**: constructors create OS handles and prepare internal state but do not start threads. The user drives the event loop by calling `get_events` on a watcher.

```odin
import fsw "odin-fsw"

// Create a native watcher for a directory. No thread is started.
w, err := fsw.watch_dir("/tmp")
assert(err == nil)
defer fsw.destroy(w)

// User-driven event loop. Each get_events call drains the OS queue
// and returns a fresh dynamic array of events.
for {
    events := fsw.get_events(w)
    for event in events {
        fmt.printf("%v: %s\n", event.kind, event.path)
    }
    delete(events) // free backing array (paths freed separately below)
    time.sleep(100 * time.Millisecond)
}
```

`get_events` performs one OS read / poll cycle and returns all events that were available. The returned `[dynamic]Event` and each `event.path` string are allocated with the allocator passed to `get_events` (defaults to `context.allocator`). Pass `context.temp_allocator` for fire-and-forget use.

```odin
// Fire-and-forget: no cleanup needed, the temp allocator handles it
events := fsw.get_events(w, context.temp_allocator)
for event in events {
    fmt.printf("%v: %s\n", event.kind, event.path)
}
```

## Constructors

All constructors return a heap-allocated pointer. Call `destroy` when done. None of the constructors take a callback or start a thread.

| Constructor | Type | Backend | Alloc |
|---|---|---|---|
| `watch_file(path)` | `^Watcher_File` | inotify/kqueue/IOCP | zero |
| `watch_dir(path)` | `^Watcher_Dir` | inotify/kqueue/IOCP | zero |
| `watch_dir_recursive(path)` | `^Watcher_Recursive` | inotify/kqueue/IOCP | map |
| `watch_file_poll(path, latency)` | `^Watcher_File_Poll` | polling | zero |
| `watch_dir_poll(path, latency)` | `^Watcher_Dir_Poll` | polling | map |
| `watch_dir_poll_recursive(path, latency)` | `^Watcher_Recursive_Poll` | polling | map |
| `watch_glob(pattern)` | `^Watcher_Glob` | recursive + filter | map |

All constructors accept an optional `allocator` parameter (defaults to `context.allocator`).

### Native watchers

Use the OS-native notification mechanism. Preferred when available.

- `watch_file` — watch a single file for changes.
- `watch_dir` — watch a directory (non-recursive, immediate children only).
- `watch_dir_recursive` — watch a directory and all subdirectories. New subdirectories are automatically watched.

### Polling watchers

Fallback for platforms without native support, or when latency-based polling is desired.

- `watch_file_poll` — stat-based polling. The user drives polling by calling `get_events`; each call performs one `stat()`. The user should `time.sleep(latency)` between calls.
- `watch_dir_poll` — snapshot-based directory polling. Each call does one snapshot diff.
- `watch_dir_poll_recursive` — recursive snapshot-based polling.

### Glob watcher

Watches a directory recursively, filtering events through a glob pattern.

```odin
w, err := fsw.watch_glob("/tmp/*.txt")
```

The glob pattern must start with a directory prefix (e.g. `/tmp/*.txt`). The watcher extracts the static prefix as the watch root, then filters events through the pattern. Only files matching the pattern trigger events.

## Events

```odin
Event :: struct {
    kind:     Event_Kind,  // Added, Removed, Modified, Renamed, Overflow, Invalidated
    path:     string,      // Absolute path of the affected file/directory
    old_path: string,      // Previous path (for Renamed events, currently unused)
    is_dir:   bool,        // True if the target is a directory
}
```

## Get Events

Pull events from a watcher. `get_events` returns all events from a single OS read / poll cycle as a `[dynamic]Event`. The backing array and the path strings inside are allocated with the `allocator` parameter (defaults to `context.allocator`).

```odin
events := fsw.get_events(w)
for event in events {
    fmt.printf("%v: %s\n", event.kind, event.path)
}

// Caller owns the returned array and must free it:
for event in events {
    delete(event.path, /* same allocator as get_events */)
}
delete(events)
```

Works with any watcher type via the procedure group.

## Destroy

Free a watcher and all its resources. The `destroy` procedure group accepts any watcher type:

```odin
fsw.destroy(w)  // works for all watcher types
```

## Rescan

Force a full rescan. Available for recursive and glob watchers:

```odin
err := fsw.rescan(w)  // works for ^Watcher_Recursive, ^Watcher_Recursive_Poll, ^Watcher_Glob
```

For non-recursive watchers, `rescan` is a no-op.

## Gotchas

### Allocator for returned events

`get_events` allocates the returned `[dynamic]Event` and its path strings with the passed allocator. The watcher's own allocator is only for the watcher's internal state (OS handles, snapshot maps). These are two different lifecycles — use the `allocator` parameter to `get_events` to control the returned data's lifecycle independently.

### Glob pattern format

`watch_glob` uses `filepath.match` for pattern matching. Patterns like `*.txt` match at the top level only; use `**/*.txt` for deeper matching if supported by your platform's `filepath.match`.

### Recursive watcher memory

`watch_dir_recursive` and `watch_glob` allocate a map to track watched subdirectories. For very deep directory trees, this uses more memory than flat watchers.

### User-driven polling

The library does not start any threads. For polling watchers, you control the poll cadence. The recommended pattern is:

```odin
for {
    events := fsw.get_events(w)
    for event in events {
        handle(event)
    }
    delete(events)
    time.sleep(latency)
}
```

For native watchers, `get_events` is non-blocking; sleep if you want to avoid a tight loop.

### Glob watcher event filtering

The glob watcher pulls events from an internal recursive watcher. Non-matching events are consumed but discarded, so a glob watcher is more efficient when most events would not match the pattern.

### Rescan after external changes

For Linux and kqueue-based recursive watchers: if subdirectories are deleted out from under the watcher, `rescan` rebuilds the watch set. For Windows, `ReadDirectoryChangesW` with `bWatchSubtree=TRUE` tracks subdirectory changes automatically, so rescan is a no-op.

### Path lifetime for glob events

Events from `watch_glob` have paths that point into the watcher's internal `matched_files` map. They are stable as long as the file remains matched. If you need to keep the path past a subsequent `get_events` call, clone it.
