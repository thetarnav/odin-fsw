# fsw — Filesystem Watcher for Odin

Cross-platform file and directory watching library. Uses native backends where available (inotify on Linux, kqueue on macOS/FreeBSD, ReadDirectoryChangesW on Windows) with a polling fallback for all platforms.

## Quick Start

```odin
import fsw "odin-fsw"

cb :: proc (event: ^fsw.Event) {
    fmt.printf("%v: %s\n", event.kind, event.path)
}

w, err := fsw.watch_file("/tmp/test.txt", cb)
assert(err == nil)
defer fsw.destroy(w)

// Watcher runs in a background thread. Events arrive via cb.
time.sleep(5 * time.Second)
```

## Constructors

All constructors return a heap-allocated pointer. Call `destroy` when done.

| Constructor | Type | Backend | Alloc |
|---|---|---|---|
| `watch_file(path, cb)` | `^Watcher_File` | inotify/kqueue/IOCP | zero |
| `watch_dir(path, cb)` | `^Watcher_Dir` | inotify/kqueue/IOCP | zero |
| `watch_dir_recursive(path, cb)` | `^Watcher_Recursive` | inotify/kqueue/IOCP | map |
| `watch_file_poll(path, cb, latency)` | `^Watcher_File_Poll` | polling | zero |
| `watch_dir_poll(path, cb, latency)` | `^Watcher_Dir_Poll` | polling | map |
| `watch_dir_poll_recursive(path, cb, latency)` | `^Watcher_Recursive_Poll` | polling | map |
| `watch_glob(pattern, cb)` | `^Watcher_Glob` | recursive + filter | map |

All constructors accept an optional `allocator` parameter (defaults to `context.allocator`).

### Native watchers

Use the OS-native notification mechanism. Preferred when available.

- `watch_file` — watch a single file for changes.
- `watch_dir` — watch a directory (non-recursive, immediate children only).
- `watch_dir_recursive` — watch a directory and all subdirectories. New subdirectories are automatically watched.

### Polling watchers

Fallback for platforms without native support, or when latency-based polling is desired.

- `watch_file_poll` — stat-based polling at the given `latency` interval.
- `watch_dir_poll` — snapshot-based directory polling.
- `watch_dir_poll_recursive` — recursive snapshot-based polling.

### Glob watcher

Watches a directory recursively, filtering events through a glob pattern.

```odin
w, _ := fsw.watch_glob("/tmp/*.txt", cb)
```

The glob pattern must start with a directory prefix (e.g. `/tmp/*.txt`). The watcher extracts the static prefix as the watch root, then filters events through the pattern. Only files matching the pattern trigger callbacks.

## Events

```odin
Event :: struct {
    kind:     Event_Kind,  // Added, Removed, Modified, Renamed, Overflow, Invalidated
    path:     string,      // Absolute path of the affected file/directory
    old_path: string,      // Previous path (for Renamed events, currently unused)
    is_dir:   bool,        // True if the target is a directory
}
```

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

## Watcher Union

The `Watcher` union type can hold any watcher pointer. Useful when you don't care about the specific type:

```odin
w: fsw.Watcher
w = w_file  // assign any ^Watcher_*
fsw.destroy(&w)  // dispatches to the correct destroy proc
```

## Gotchas

### Callback context

Watcher threads restore the caller's `context` (including `user_ptr`) before invoking your callback. You can set `context.user_ptr` before creating a watcher and read it inside the callback — it will be the same value.

### Path lifetime

The `event.path` string passed to your callback is only valid during the callback invocation. If you need to keep it, clone it.

### Glob pattern format

`watch_glob` uses `filepath.match` for pattern matching. Patterns like `*.txt` match at the top level only; use `**/*.txt` for deeper matching if supported by your platform's `filepath.match`.

### Recursive watcher memory

`watch_dir_recursive` and `watch_glob` allocate a map to track watched subdirectories. For very deep directory trees, this uses more memory than flat watchers.

### Thread safety

**Callbacks run on the watcher's background thread, not your main thread.** This means your callback code executes concurrently with whatever your main thread is doing. If the callback accesses shared state (slices, maps, counters), you must synchronize access yourself:

```odin
mu: sync.Mutex
events: [dynamic]Event

my_cb :: proc(e: ^Event) {
    sync.mutex_lock(&mu)
    append(&events, e^)
    sync.mutex_unlock(&mu)
}
```

Don't call `destroy` or `rescan` from inside a callback — it would deadlock trying to join the thread that's running the callback.

### Thread-per-watcher model

Each native watcher creates a dedicated background thread. This is fine for a handful of watchers (1–10), but each thread costs ~8KB of stack space. If you need hundreds of watchers, consider using polling watchers (which share the main thread's time) or consolidating watches into fewer `watch_dir_recursive` calls.
