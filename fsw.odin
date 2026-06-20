// fsw.odin — Cross-platform file & directory watching for Odin.
//
// Pull-based API. The library does not start threads; the user drives the
// event loop. Each call to `get_events` returns all events from a single
// OS read / poll cycle, as a `[]Event` slice. The backing array and
// path strings are allocated with the allocator passed to `get_events`
// (defaults to `context.allocator`). Use `context.temp_allocator` for
// fire-and-forget use.
//
// Constructors: `watch_file`, `watch_dir`, `watch_dir_recursive`,
// `watch_file_poll`, `watch_dir_poll`, `watch_dir_poll_recursive`,
// `watch_glob`. They return `^Watcher_*` and an `Error`.
//
// Usage:
//   w, err := watch_dir("/tmp")
//   defer destroy(w)
//   for {
//       time.sleep(100 * time.Millisecond)
//       events := get_events(w, context.temp_allocator)
//       for ev in events {fmt.println(ev)}
//   }

package fsw

import "core:strings"
import "core:mem"
import "core:os"
import "core:path/filepath"

// === Event types ===

// Event_Kind describes the type of filesystem change detected.
Event_Kind :: enum {
	Added,        // A new file or directory was created.
	Removed,      // A file or directory was deleted.
	Modified,     // A file's content or metadata changed.
	Renamed,      // A file or directory was moved/renamed.
	Overflow,     // The OS event queue overflowed; events may have been lost.
	Invalidated,  // The watch target was unmounted or became invalid.
}

// Error codes returned by watcher constructors and rescan procs.
Error :: enum {
	None,                // No error.
	Invalid_Path,        // The path does not exist or cannot be resolved.
	Backend_Init_Failed, // The OS-native watcher could not be created.
}

// Event represents a single filesystem change. The path string is allocated
// with the allocator passed to get_events. Free it with that allocator.
Event :: struct {
	kind:   Event_Kind, // What happened.
	path:   string,     // Absolute path of the affected file/directory.
	is_dir: bool,       // True if the target is a directory.
}

// === Watcher types ===

// Watcher_File watches a single file using the OS-native backend.
Watcher_File :: struct {
	path:             string,
	allocator:        mem.Allocator,
	using native:     Native_File,
	_track_resources: Track_Resources, // for testing
}

// Watcher_Dir watches a directory (non-recursive) using the OS-native backend.
// Only immediate children are reported.
Watcher_Dir :: struct {
	path:             string,
	allocator:        mem.Allocator,
	using native:     Native_Dir,
	_track_resources: Track_Resources, // for testing
}

// Watcher_Recursive watches a directory and all its subdirectories.
// Allocates a map to track per-subdirectory watches. New subdirectories
// are automatically watched when detected.
Watcher_Recursive :: struct {
	path:             string,
	allocator:        mem.Allocator,
	using native:     Native_Recursive,
	_track_resources: Track_Resources, // for testing
}

// Watcher_File_Poll watches a single file by stat-based polling.
// The prev field holds the last known state inline (no extra allocation).
Watcher_File_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	prev:      File_Info,
}

// Watcher_Dir_Poll watches a directory by snapshot-based polling.
// Allocates a map of file info snapshots, replaced each polling interval.
Watcher_Dir_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	prev:      map[string]File_Info,
}

// Watcher_Recursive_Poll watches a directory recursively by snapshot-based polling.
// Allocates a map of file info snapshots covering all subdirectories.
Watcher_Recursive_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	prev:      map[string]File_Info,
}

// Watcher_Glob watches files matching a glob pattern within a directory tree.
// Internally embeds a Watcher_Recursive and filters its events through the
// glob pattern. Tracks matched files in a map. Only non-directory files
// that match the pattern trigger Added/Modified/Removed events.
Watcher_Glob :: struct {
	pattern:       string,
	allocator:     mem.Allocator,
	matched_files: map[string]bool,
	inner:         Watcher_Recursive,
}

// Watcher is an opaque tagged union over all watcher types. Use it to store
// a watcher without committing to a specific kind — the `destroy`, `get_events`,
// and `rescan` proc groups all dispatch on the union as well.
Watcher :: union {
	^Watcher_File,
	^Watcher_Dir,
	^Watcher_Recursive,
	^Watcher_File_Poll,
	^Watcher_Dir_Poll,
	^Watcher_Recursive_Poll,
	^Watcher_Glob,
}

// === Constructors — all heap-allocate, return pointers ===

// watch_file creates a native watcher for a single file.
// Initializes OS handles. Does NOT start a thread.
// Call destroy(w) when done.
@require_results
watch_file :: proc (path: string, allocator := context.allocator) -> (^Watcher_File, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	w, new_err := new(Watcher_File, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_File{
		path      = p,
		allocator = allocator,
	}

	e := backend_file_init(w)
	if e != .None {
		delete(w.path, allocator)
		free(w, allocator)
		return nil, e
	}

	return w, .None
}

// watch_dir creates a native watcher for a directory (non-recursive).
// Initializes OS handles. Does NOT start a thread.
// Only events in the immediate directory are reported.
@require_results
watch_dir :: proc (path: string, allocator := context.allocator) -> (^Watcher_Dir, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	w, new_err := new(Watcher_Dir, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_Dir{
		path      = p,
		allocator = allocator,
	}

	e := backend_dir_init(w)
	if e != .None {
		delete(w.path, allocator)
		free(w, allocator)
		return nil, e
	}

	return w, .None
}

// watch_dir_recursive creates a native watcher for a directory tree.
// Initializes OS handles and registers all subdirectories. Does NOT start a thread.
// Subdirectories created after init are auto-watched when the kernel reports an
// .Added event for them (on the first get_events call that processes the event).
@require_results
watch_dir_recursive :: proc (path: string, allocator := context.allocator) -> (^Watcher_Recursive, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	w, new_err := new(Watcher_Recursive, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_Recursive{
		path      = p,
		allocator = allocator,
	}

	e := backend_rec_init(w)
	if e != .None {
		delete(w.path, allocator)
		free(w, allocator)
		return nil, e
	}

	return w, .None
}

// watch_file_poll creates a polling watcher for a single file.
// No thread is started. The user drives polling by calling get_events.
// Each call performs a single stat() check.
@require_results
watch_file_poll :: proc (path: string, allocator := context.allocator) -> (^Watcher_File_Poll, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	os_fi, stat_err := os.stat(p, allocator)
	if stat_err != nil do return nil, .Invalid_Path
	os.file_info_delete(os_fi, allocator)

	fi := File_Info{
		is_dir = os_fi.type == .Directory,
		size   = os_fi.size,
		mtime  = os_fi.modification_time,
		inode  = os_fi.inode,
	}
	w, new_err := new(Watcher_File_Poll, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_File_Poll{
		path      = p,
		allocator = allocator,
		prev      = fi,
	}

	return w, .None
}

// watch_dir_poll creates a polling watcher for a directory.
// No thread is started. Each get_events call performs a single
// snapshot diff.
@require_results
watch_dir_poll :: proc (path: string, allocator := context.allocator) -> (^Watcher_Dir_Poll, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	prev := make(map[string]File_Info, allocator)
	snapshot_dir_alloc(p, &prev, allocator, fullpath=true, recursive=false)

	w, new_err := new(Watcher_Dir_Poll, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_Dir_Poll{
		path      = p,
		allocator = allocator,
		prev      = prev,
	}

	return w, .None
}

// watch_dir_poll_recursive creates a polling watcher for a directory tree.
// No thread is started. Each get_events call performs a single
// recursive snapshot diff.
@require_results
watch_dir_poll_recursive :: proc (path: string, allocator := context.allocator) -> (^Watcher_Recursive_Poll, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	prev := make(map[string]File_Info, allocator)
	snapshot_dir_alloc(p, &prev, allocator, fullpath=true, recursive=true)
	w, new_err := new(Watcher_Recursive_Poll, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed
	w^ = Watcher_Recursive_Poll{
		path      = p,
		allocator = allocator,
		prev      = prev,
	}
	return w, .None
}

// watch_glob creates a watcher that filters events through a glob pattern.
// The static prefix of the pattern is used as the watch root (e.g. "/tmp" from "/tmp/*.txt").
// The directory is watched recursively; only files matching the pattern trigger events.
// No thread is started. Performs an initial scan to detect pre-existing matching files.
@require_results
watch_glob :: proc (pattern: string, allocator := context.allocator) -> (^Watcher_Glob, Error) {

	root, pat := glob_extract_root(pattern)
	p, err := filepath.abs(root, allocator)
	if err != nil do return nil, .Invalid_Path

	w, new_err := new(Watcher_Glob, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_Glob{
		pattern   = pat,
		allocator = allocator,
	}
	w.inner = {
		path      = p,
		allocator = allocator,
	}

	e := backend_rec_init(&w.inner)
	if e != .None {
		delete(w.inner.path, allocator)
		free(w, allocator)
		return nil, e
	}

	w.matched_files = make(map[string]bool, allocator)

	// initial scan
	glob_scan_dir(w, w.inner.path)

	return w, .None
}

// === destroy ===

// destroy_file stops and frees a Watcher_File. Safe to call with nil.
destroy_file :: proc (w: ^Watcher_File) {
	if w == nil do return
	backend_file_destroy(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir stops and frees a Watcher_Dir. Safe to call with nil.
destroy_dir :: proc (w: ^Watcher_Dir) {
	if w == nil do return
	backend_dir_destroy(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_rec stops and frees a Watcher_Recursive. Safe to call with nil.
destroy_rec :: proc (w: ^Watcher_Recursive) {
	if w == nil do return
	backend_rec_destroy(w)
	backend_rec_native_cleanup(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_file_poll stops and frees a Watcher_File_Poll. Safe to call with nil.
destroy_file_poll :: proc (w: ^Watcher_File_Poll) {
	if w == nil do return
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir_poll stops and frees a Watcher_Dir_Poll. Safe to call with nil.
destroy_dir_poll :: proc (w: ^Watcher_Dir_Poll) {
	if w == nil do return
	for path in w.prev {
		delete(path, w.allocator)
	}
	delete(w.prev)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_rec_poll stops and frees a Watcher_Recursive_Poll. Safe to call with nil.
destroy_rec_poll :: proc (w: ^Watcher_Recursive_Poll) {
	if w == nil do return
	for path in w.prev {
		delete(path, w.allocator)
	}
	delete(w.prev)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_glob stops and frees a Watcher_Glob and its embedded recursive watcher. Safe to call with nil.
destroy_glob :: proc (w: ^Watcher_Glob) {
	if w == nil do return
	backend_rec_destroy(&w.inner)
	backend_rec_native_cleanup(&w.inner)
	delete(w.inner.path, w.allocator)
	for path in w.matched_files {
		delete(path, w.allocator)
	}
	delete(w.matched_files)
	free(w, w.allocator)
}

// destroy is a procedure group that accepts any watcher type.
// Call destroy(w) with any ^Watcher_* or a Watcher union to free it.
destroy :: proc {
	destroy_file,
	destroy_dir,
	destroy_rec,
	destroy_file_poll,
	destroy_dir_poll,
	destroy_rec_poll,
	destroy_glob,
	destroy_watcher,
}

// destroy_watcher frees a Watcher union, dispatching to the correct destroy_*.
destroy_watcher :: proc (w: Watcher) {
	switch v in w {
	case ^Watcher_File:           destroy(v)
	case ^Watcher_Dir:            destroy(v)
	case ^Watcher_Recursive:      destroy(v)
	case ^Watcher_File_Poll:      destroy(v)
	case ^Watcher_Dir_Poll:       destroy(v)
	case ^Watcher_Recursive_Poll: destroy(v)
	case ^Watcher_Glob:           destroy(v)
	}
}

// === get_events ===

// get_events_file returns all available events from a Watcher_File.
// The returned slice's backing array and the path strings inside are
// allocated with `allocator` (defaults to context.allocator).
// Pass context.temp_allocator if you don't plan to store the events.
// For native backends, performs a non-blocking read of the OS notification queue.
@require_results
get_events_file :: proc (w: ^Watcher_File, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_file_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_dir returns all available events from a Watcher_Dir.
// For native backends, performs a non-blocking read of the OS notification queue.
@require_results
get_events_dir :: proc (w: ^Watcher_Dir, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_dir_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_rec returns all available events from a Watcher_Recursive.
// For native backends, performs a non-blocking read of the OS notification queue.
@require_results
get_events_rec :: proc (w: ^Watcher_Recursive, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_rec_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

get_events_glob :: glob_get_events

// get_events_file_poll returns all available events from a Watcher_File_Poll.
@require_results
get_events_file_poll :: proc (w: ^Watcher_File_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 4, allocator)
	poll_file_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_dir_poll returns all available events from a Watcher_Dir_Poll.
@require_results
get_events_dir_poll :: proc (w: ^Watcher_Dir_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	poll_dir_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_rec_poll returns all available events from a Watcher_Recursive_Poll.
@require_results
get_events_rec_poll :: proc (w: ^Watcher_Recursive_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	poll_rec_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events is a procedure group that accepts any watcher type.
// Returns all available events from a single OS read / poll cycle.
// The returned `[]Event` and its `path` strings must be freed by the caller — use `delete_events(events)`.
get_events :: proc {
	get_events_file,
	get_events_dir,
	get_events_rec,
	get_events_file_poll,
	get_events_dir_poll,
	get_events_rec_poll,
	get_events_glob,
	get_events_watcher,
}

// get_events_watcher returns events from a Watcher union, dispatching to the correct get_events_*.
@require_results
get_events_watcher :: proc (w: Watcher, allocator := context.allocator) -> []Event {
	switch v in w {
	case ^Watcher_File:           return get_events(v, allocator)
	case ^Watcher_Dir:            return get_events(v, allocator)
	case ^Watcher_Recursive:      return get_events(v, allocator)
	case ^Watcher_File_Poll:      return get_events(v, allocator)
	case ^Watcher_Dir_Poll:       return get_events(v, allocator)
	case ^Watcher_Recursive_Poll: return get_events(v, allocator)
	case ^Watcher_Glob:           return get_events(v, allocator)
	}
	return {}
}

clone_event :: proc (e: Event, allocator := context.allocator, loc := #caller_location) -> Event {
	e := e
	e.path = strings.clone(e.path, allocator, loc)
	return e
}

// helper for freeing the events slice returned by get_events
delete_events :: proc (events: []Event, allocator := context.allocator, loc := #caller_location) -> (err: mem.Allocator_Error) {
	for e in events {
		delete(e.path, allocator, loc) or_return
	}
	delete(events, allocator, loc) or_return
	return
}

// === rescan ===

// rescan_rec forces a full rescan of a recursive watcher, re-registering all inotify/kqueue watches.
rescan_rec :: backend_rec_rescan

// rescan_rec_poll forces a full rescan of a polling recursive watcher, rebuilding the snapshot.
rescan_rec_poll :: proc (w: ^Watcher_Recursive_Poll) -> Error {
	delete(w.prev)
	w.prev = make(map[string]File_Info, w.allocator)
	snapshot_dir_alloc(w.path, &w.prev, w.allocator, fullpath=true, recursive=true)
	return .None
}

// rescan_glob forces a full rescan of a glob watcher, re-registering watches and re-matching files.
rescan_glob :: proc (w: ^Watcher_Glob) -> (err: Error) {
	rescan_rec(&w.inner) or_return
	glob_rescan(w)
	return .None
}

// rescan is a procedure group that accepts any watcher type.
// For recursive and glob watchers, forces a full re-scan.
// For non-recursive watchers, returns .None (no-op).
rescan :: proc {
	rescan_rec,
	rescan_rec_poll,
	rescan_glob,
	rescan_watcher,
}

// rescan_watcher forces a rescan of a Watcher union, dispatching to the correct rescan_*.
@require_results
rescan_watcher :: proc (w: Watcher) -> Error {
	#partial switch v in w {
	case ^Watcher_Recursive:      return rescan(v)
	case ^Watcher_Recursive_Poll: return rescan(v)
	case ^Watcher_Glob:           return rescan(v)
	}
	return .None
}
