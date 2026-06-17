# odin-fsw — File System Watcher for Odin

## Package Layout

```
fsw/
  fsw.odin              # public API, types, watcher constructors, `when` dispatch
  event.odin            # Event type, normalization helpers
  watch.odin            # recursive state machine (Watcher_Recursive internals)
  snapshot.odin         # polling snapshot logic (File_Info, diff)
  backend_poll.odin     # polling backend (all watcher types)
  backend_linux.odin    # inotify + epoll
  backend_windows.odin  # ReadDirectoryChangesW + IOCP
  backend_darwin.odin   # FSEvents (dirs) + kqueue (files)
  backend_freebsd.odin  # kqueue
  backend_posix.odin    # shared POSIX helpers (wake pipe/eventfd, fd utils)
  glob.odin             # Watcher_Glob internals
  path.odin             # canonicalization, glob prefix extraction
tests/
  watch_test.odin       # integration harness (shared mutation script)
  poll_test.odin        # polling-specific edge cases
  glob_test.odin        # glob expansion tests
```

Package declaration: `package fsw`

## Core Types

```odin
Event_Kind :: enum {
    Added,
    Removed,
    Modified,
    Renamed,
    Overflow,       // backend lost events, rescan required
    Invalidated,    // watch became invalid (unmount, delete, etc.)
}

Error :: enum {
    None,
    Invalid_Path,
    Backend_Init_Failed,
}

Event :: struct {
    kind:     Event_Kind,
    path:     string,     // affected path — valid only during callback, copy to retain
    old_path: string,     // set for Renamed when backend provides old+new
    is_dir:   bool,
}
```

No `Mode`, `Target`, `Target_Kind`, `Config`, or `Backend_Id` types. The watcher variant you construct determines the mode and target kind.

## Watcher Types

Seven distinct types, each self-contained. All start their backend thread on construction.

```odin
// Single file — native. Zero alloc.
// inotify: direct watch. kqueue: fd + EVFILT_VNODE. Windows: parent dir + basename filter.
Watcher_File :: struct {
    callback:      Event_Callback,
    path:          string,         // borrowed from caller
    running:       sync.atomic.Bool,
    native_handle: int,            // inotify wd / kqueue fd / parent dir handle
    parent_dir:    string,         // Windows only — dir being watched
    thread:        ^thread.Thread,
}

// Non-recursive directory — native. Zero alloc.
// Single watch handle on the directory. Reports changes within it.
Watcher_Dir :: struct {
    callback:      Event_Callback,
    path:          string,
    running:       sync.atomic.Bool,
    native_handle: int,
    thread:        ^thread.Thread,
}

// Recursive directory — native. Allocates map.
// inotify: watches per subdirectory. Windows/FSEvents: native subtree.
Watcher_Recursive :: struct {
    callback:  Event_Callback,
    path:      string,
    running:   sync.atomic.Bool,
    watches:   map[int]string,      // native_handle → subdir path (inotify). Single handle for Windows/FSEvents.
    thread:    ^thread.Thread,
    allocator: mem.Allocator,
}

// Single file — polling. Inline snapshot, no heap alloc.
Watcher_File_Poll :: struct {
    callback: Event_Callback,
    path:     string,
    running:  sync.atomic.Bool,
    latency:  time.Duration,
    prev:     File_Info,           // previous stat snapshot — inline, no heap
    thread:   ^thread.Thread,
}

// Non-recursive directory — polling. Allocates file map.
Watcher_Dir_Poll :: struct {
    callback:  Event_Callback,
    path:      string,
    running:   sync.atomic.Bool,
    latency:   time.Duration,
    prev:      map[string]File_Info, // filename → last known state
    thread:    ^thread.Thread,
    allocator: mem.Allocator,
}

// Recursive directory — polling. Allocates file map + subdir tracking.
Watcher_Recursive_Poll :: struct {
    callback:  Event_Callback,
    path:      string,
    running:   sync.atomic.Bool,
    latency:   time.Duration,
    prev:      map[string]File_Info,
    thread:    ^thread.Thread,
    allocator: mem.Allocator,
}

// Glob — watches a directory recursively, filters by glob pattern.
// Tracks matched files. Reports Added/Removed as files appear/disappear.
// Allocates for matched_files map and inner recursive watcher.
Watcher_Glob :: struct {
    callback:      Event_Callback,
    pattern:       string,              // the glob pattern (e.g. "**/*.odin")
    running:       sync.atomic.Bool,
    matched_files: map[string]bool,     // canonical path → currently matched
    inner:         Watcher_Recursive,   // the underlying recursive watcher
    allocator:     mem.Allocator,
}
```

## Watcher Union

Generic wrapper for users who don't care about the specific watcher variant:

```odin
Watcher :: union {
    ^Watcher_File,
    ^Watcher_Dir,
    ^Watcher_Recursive,
    ^Watcher_File_Poll,
    ^Watcher_Dir_Poll,
    ^Watcher_Recursive_Poll,
    ^Watcher_Glob,
}
```

Overloaded procs work on both the union and individual types:

```odin
// === destroy — overloaded for all types + union ===

destroy :: proc(w: ^Watcher_File)           { ... }
destroy :: proc(w: ^Watcher_Dir)            { ... }
destroy :: proc(w: ^Watcher_Recursive)      { ... }
destroy :: proc(w: ^Watcher_File_Poll)      { ... }
destroy :: proc(w: ^Watcher_Dir_Poll)       { ... }
destroy :: proc(w: ^Watcher_Recursive_Poll) { ... }
destroy :: proc(w: ^Watcher_Glob)           { ... }
destroy :: proc(w: ^Watcher)                { // dispatches to variant }

// === rescan — overloaded for types that support it ===

rescan :: proc(w: ^Watcher_Recursive)      -> Error { ... }
rescan :: proc(w: ^Watcher_Recursive_Poll) -> Error { ... }
rescan :: proc(w: ^Watcher_Glob)           -> Error { ... }
rescan :: proc(w: ^Watcher)                -> Error { // dispatches }

// === Casting helpers ===

// Convert any specific watcher pointer to Watcher union
as_watcher :: proc(w: ^Watcher_File)           -> Watcher { return w }
as_watcher :: proc(w: ^Watcher_Dir)            -> Watcher { return w }
// ... etc for all types
```

Usage with the union:

```odin
// User who doesn't care about specific type
w: Watcher
w = as_watcher(watch_file("foo.txt", cb))
defer destroy(&w)

// Or store mixed types
watchers := make([dynamic]Watcher)
append(&watchers, as_watcher(watch_file("a.txt", cb)))
append(&watchers, as_watcher(watch_dir("/tmp", cb)))
defer for w in watchers { destroy(&w) }

// Specific type usage still works directly
wf, _ := watch_file("foo.txt", cb)
defer destroy(&wf)
```

## API Surface

```odin
// === Constructors — start thread immediately, return running watcher ===

// File, native. Zero alloc.
watch_file :: proc(path: string, cb: Event_Callback) -> (Watcher_File, Error)

// File, polling. No heap alloc (inline File_Info snapshot).
watch_file_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration) -> (Watcher_File_Poll, Error)

// Directory, native, non-recursive. Zero alloc.
watch_dir :: proc(path: string, cb: Event_Callback) -> (Watcher_Dir, Error)

// Directory, native, recursive. Allocates watcher map.
watch_dir_recursive :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (Watcher_Recursive, Error)

// Directory, polling, non-recursive. Allocates file map.
watch_dir_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (Watcher_Dir_Poll, Error)

// Directory, polling, recursive. Allocates file map + subdir tracking.
watch_dir_poll_recursive :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (Watcher_Recursive_Poll, Error)

// Glob — watches directory recursively, filters by pattern. Allocates.
// Reports Added for new matching files, Removed for deleted matches.
watch_glob :: proc(pattern: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Glob, Error)

// === Lifecycle (overloaded — see Watcher Union section above) ===
// destroy :: proc(w: ^<any watcher type>)
// rescan  :: proc(w: ^<recursive watcher type>) -> Error

// === Callback type ===

Event_Callback :: proc(event: ^Event)
```

No `run` proc. Watchers are running from the moment they're returned. No `stop` proc — `destroy` stops and frees.

**Allocation rules:**
- Native watchers (`watch_file`, `watch_dir`): zero heap alloc. Path string borrowed, not copied.
- Polling file (`watch_file_poll`): no heap alloc. `File_Info` snapshot lives inline in the struct.
- Polling dir/recursive, native recursive, and glob: allocator required.
- `watch_glob`: allocator required. Returns `^Watcher_Glob`.

## Glob Watching

`Watcher_Glob` is a proper watcher, not a convenience wrapper. It watches a directory recursively and filters events through a glob pattern, tracking which files currently match.

**How it works:**

1. Extract watch root from pattern: longest static prefix before first wildcard (`*`, `?`, `{`, `[`).
   - `src/**/*.odin` → root = `src/`
   - `*.go` → root = `.`
   - `**/*.test` → root = `.`
2. Determine if recursive: pattern contains `**`.
3. Create `Watcher_Recursive` on the root directory.
4. Initial glob expansion populates `matched_files`.
5. Internal callback filters all recursive events through the glob pattern:
   - New file matches pattern and not in `matched_files` → Added, add to map.
   - File in `matched_files` was modified → Modified.
   - File in `matched_files` was removed → Removed, delete from map.
   - Directory events that don't match pattern → ignored.

**Pattern matching**: paths are stored canonical, relative to watch root. Pattern is matched against relative path using `path.match`.

**Example:**
```odin
w, err := watch_glob("src/**/*.odin", on_change)
defer destroy(&w)
// Reports Added when new .odin file appears anywhere under src/
// Reports Removed when .odin file is deleted
// Reports Modified when .odin file content changes
// Ignores non-.odin files, even though they're watched internally
```

**rescan**: re-expands glob, diffs against `matched_files`, emits Added/Removed for changes. Delegates to inner `Watcher_Recursive.rescan` for backend state.

## Backend Interface

Each backend is a set of procs, selected at compile-time via `when ODIN_OS`. Each watcher type has its own backend procs:

```odin
// Native file watcher
backend_file_init    :: proc(w: ^Watcher_File) -> Error        // open handle, start thread
backend_file_destroy :: proc(w: ^Watcher_File)                  // close handle, join thread

// Native dir watcher
backend_dir_init     :: proc(w: ^Watcher_Dir) -> Error
backend_dir_destroy  :: proc(w: ^Watcher_Dir)

// Native recursive watcher
backend_rec_init     :: proc(w: ^Watcher_Recursive) -> Error
backend_rec_destroy  :: proc(w: ^Watcher_Recursive)

// Polling variants share snapshot logic, just differ in event loop
backend_poll_file_run  :: proc(w: ^Watcher_File_Poll)          // stat loop
backend_poll_dir_run   :: proc(w: ^Watcher_Dir_Poll)           // readdir + diff loop
backend_poll_rec_run   :: proc(w: ^Watcher_Recursive_Poll)     // recursive walk + diff loop
```

No vtable. `when` dispatch at each constructor and destroy call site.

## Event Delivery

Per-event callback. No batching buffer.

```odin
// Inside backend_run for inotify:
for event in inotify_events {
    e := Event{kind = normalize(event), path = build_path(event)}
    w.callback(&e)  // stack-local Event, pointer valid during callback only
}
```

**Path lifetime**: `event.path` and `event.old_path` point into the backend's read buffer (inotify) or are stack-allocated (polling). Valid only during the callback. User must copy to retain.

**Overflow delivery**: when the backend detects overflow (`IN_Q_OVERFLOW`, buffer overflow), it calls the callback with an `Event{kind = .Overflow}`. The user should call `rescan` if they need to recover.

## Recursive Directory Watching

State machine inside `Watcher_Recursive`:

```
watches: map[int]string   // native_handle → canonical path
```

1. **Initial scan**: walk tree, `inotify_add_watch` on each subdir, populate map.
2. **On subdir Added** (`IN_CREATE|IN_ISDIR`): add watch, insert into map.
3. **On subdir Removed** (`IN_DELETE_SELF`): remove watch, delete from map.
4. **On subdir Rename**: remove old watch, add new watch, update map.
5. **On Overflow/Invalidated**: notify callback, user calls `rescan` to rebuild.

For Windows/FSEvents: single handle watches the whole subtree. `watches` map has one entry or is empty (handle-only).

## Single-File Watching

- **inotify**: `inotify_add_watch(fd, path, IN_MODIFY|IN_CREATE|IN_DELETE|IN_MOVE)` — direct.
- **kqueue**: open file, `kevent` register `EVFILT_VNODE`.
- **Windows**: open parent dir, `ReadDirectoryChangesW`, filter by basename in event processing.
- **Polling**: `stat(path)`, compare mtime/size with `prev`.

Windows `Watcher_File` stores `parent_dir` (the dir handle) and `path` (the target filename for filtering).

## Event Normalization

### inotify → Event_Kind
| inotify flag | Event_Kind | Notes |
|---|---|---|
| `IN_CREATE` | Added | |
| `IN_DELETE` | Removed | |
| `IN_MODIFY`, `IN_CLOSE_WRITE` | Modified | coalesce duplicates |
| `IN_MOVED_FROM` + `IN_MOVED_TO` (same cookie) | Renamed | old_path from MOVED_FROM |
| `IN_MOVED_FROM` without pair | Removed | lost rename pair |
| `IN_Q_OVERFLOW` | Overflow | |
| `IN_UNMOUNT`, `IN_IGNORED` | Invalidated | |

### ReadDirectoryChangesW → Event_Kind
| Windows action | Event_Kind | Notes |
|---|---|---|
| `FILE_ACTION_ADDED` | Added | |
| `FILE_ACTION_REMOVED` | Removed | |
| `FILE_ACTION_MODIFIED` | Modified | expect duplicates |
| `FILE_ACTION_RENAMED_OLD_NAME` + `NEW_NAME` | Renamed | |
| buffer overflow | Overflow | |

### kqueue → Event_Kind
| kqueue flag | Event_Kind | Notes |
|---|---|---|
| `NOTE_WRITE` | Modified | dir: needs readdir diff |
| `NOTE_DELETE` | Removed | |
| `NOTE_RENAME` | Renamed | no old_path |
| `NOTE_ATTRIB` | Modified | |
| `NOTE_EXTEND` | Modified | |
| `NOTE_LINK` | Modified | |
| `NOTE_REVOKE` | Invalidated | |

### FSEvents → Event_Kind
| FSEvents flag | Event_Kind | Notes |
|---|---|---|
| `kFSEventStreamEventFlagItemCreated` | Added | |
| `kFSEventStreamEventFlagItemRemoved` | Removed | |
| `kFSEventStreamEventFlagItemModified` | Modified | |
| `kFSEventStreamEventFlagItemRenamed` | Renamed | no old_path |
| `kFSEventStreamEventFlagItemIsDir` | set `is_dir=true` | |
| `kFSEventStreamEventFlagMustScanSubDirs` | Overflow | |

**Darwin strategy**: FSEvents for `watch_dir_recursive`. kqueue `EVFILT_VNODE` for `watch_file`. Backend selects automatically.

### Polling → Event_Kind
- New path in snapshot → Added
- Path gone from snapshot → Removed
- mtime/size changed → Modified
- inode change → Renamed (best-effort)

## Snapshot (Polling Backends)

```odin
File_Info :: struct {
    path:   string,
    is_dir: bool,
    size:   i64,
    mtime:  time.Time,
    inode:  u64,         // 0 on Windows (use file index)
}
```

- `Watcher_File_Poll.prev`: single `File_Info` inline in struct. No heap.
- `Watcher_Dir_Poll.prev`: `map[string]File_Info` keyed by filename. Heap allocated.
- `Watcher_Recursive_Poll.prev`: `map[string]File_Info` keyed by canonical path. Heap allocated.
- Use `os.stat` for metadata. Use `os.read_directory` for dir enumeration.

## Error Handling

- All constructors return `Error`.
- `Error.Backend_Init_Failed` is fatal — watcher is not usable, do not call `destroy`.
- Per-event errors (stat failure, permission denied) logged to `log.err`, do not stop the watcher.
- Overflow is delivered as an `Event_Kind.Overflow` event, not an error.

## Thread Safety

- Each watcher owns one backend thread (started at construction). `Watcher_Glob` shares the inner `Watcher_Recursive`'s thread.
- `destroy` is safe to call from any thread (sets atomic flag, joins thread).
- Callback is invoked from the backend thread. User must synchronize if forwarding to other threads.
- `rescan` sets a flag; safe to call from callback. Rescan runs on the next loop iteration.
- Watchers are independent — no shared state between them.

## Testing Plan

### Integration Harness

Single mutation script, run per watcher type:

```
1. Create file A           → expect Added(A)
2. Modify file A           → expect Modified(A)
3. Rename A → B            → expect Renamed(B, old=A) or Removed(A) + Added(B)
4. Create dir D/           → expect Added(D)          [dir/recursive/glob only]
5. Create file D/E         → expect Added(D/E)        [recursive/glob only]
6. Move D/ → D2/           → expect rename tree       [recursive/glob only]
7. Delete D2/ recursively  → expect Removed events    [recursive/glob only]
8. Burst: create 1000 files rapidly → expect subset + possible Overflow
9. Truncate file B         → expect Modified(B)
10. Replace file B atomically (write tmp + rename) → expect Modified or Renamed
```

Assertions: final filesystem state correct. Event set is a superset of expected (coalescing/duplicates tolerated). No order assertion beyond causality.

### Glob-Specific

- New file matching pattern appears → Added event.
- Matching file deleted → Removed event.
- New file NOT matching pattern → no event.
- Pattern with `**` matches in newly created subdirectories.
- Pattern without `**` only matches in root directory.
- rescan after Overflow restores correct matched_files state.

### Edge Cases

- **Rename storm**: rapid A→B→C→D, verify at least A→D or full chain.
- **Atomic save**: write tmp, rename over target.
- **Rapid temp files**: create/delete 100 files in 10ms. No crash.
- **Symlink loop**: watch dir with symlink cycle. No infinite recursion.
- **File replaced by rename**: watch X, rename Y→X.
- **Overflow forced** (Linux): burst to trigger `IN_Q_OVERFLOW`. Verify `rescan` restores state.
- **Deep tree**: 100+ nested dirs. Recursive watch registers all.

### Polling-Specific

- Snapshot diff detects all change types.
- Latency config controls poll interval.
- Inode reuse detection (file deleted + new file at same path).

## Implementation Order

1. **Core types** (`fsw.odin`, `event.odin`) — Event, Error, Event_Kind, Event_Callback, Watcher union.
2. **Polling file watcher** (`backend_poll.odin`, `snapshot.odin`) — `Watcher_File_Poll`, `watch_file_poll`, `destroy`. First working watcher.
3. **Polling dir watchers** — `Watcher_Dir_Poll`, `Watcher_Recursive_Poll`. `snapshot.odin` diff logic.
4. **Integration test harness** — mutation script against all polling watchers.
5. **Linux/inotify file watcher** (`backend_linux.odin`) — `Watcher_File`, `watch_file`.
6. **Linux/inotify dir watchers** — `Watcher_Dir`, `Watcher_Recursive` with subdir state machine.
7. **Glob watcher** (`glob.odin`) — `Watcher_Glob`, `watch_glob`, pattern matching, matched_files tracking.
8. **Windows backend** (`backend_windows.odin`) — IOCP + ReadDirectoryChangesW for all types.
9. **macOS backend** (`backend_darwin.odin`) — FSEvents for recursive, kqueue for file.
10. **FreeBSD backend** (`backend_freebsd.odin`) — kqueue.
11. **Recovery hardening** — test overflow/invalidation on all backends.

## Design Constraints

- No dynamic backend switching. Backend is compile-time per OS.
- No Config struct. Parameters are inline in constructor calls with sensible defaults.
- No add/remove targets. One watcher = one target. Compose by creating multiple watchers.
- No batching. Per-event callback. Backend iterates and calls for each event.
- No event filtering in the core. User filters in their callback. (Glob watcher is an exception — it filters by pattern internally.)
- No debouncing in the core.
- Paths are canonical (absolute, cleaned). Resolved at construction.
- Native watchers borrow the path string (zero alloc). Polling/dir watchers copy via allocator.
- No dependencies outside `core` (os, path/filepath, sys, mem, sync, time, fmt).
