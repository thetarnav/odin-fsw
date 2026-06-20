// fsw.odin — Cross-platform file & directory watching for Odin.
//
// Pull-based API. The library does not start threads; the user drives the
// event loop. Each call to `get_events` returns all events accumulated
// since the last call, as a fresh `[dynamic]Event` allocated with the
// watcher's allocator. The caller is responsible for freeing it.
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
//       events := get_events(w)
//       for ev in events { fmt.println(ev) }
//       delete(events)
//   }

package fsw

import "core:strings"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

// === Watcher types ===

// Watcher_File watches a single file using the OS-native backend.
Watcher_File :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_File,
	_track_resources: (Track_Resources when ODIN_TEST else struct {}),
}

// Watcher_Dir watches a directory (non-recursive) using the OS-native backend.
// Only immediate children are reported.
Watcher_Dir :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_Dir,
	_track_resources: (Track_Resources when ODIN_TEST else struct {}),
}

// Watcher_Recursive watches a directory and all its subdirectories.
// Allocates a map to track per-subdirectory watches. New subdirectories
// are automatically watched when detected.
Watcher_Recursive :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_Recursive,
	_track_resources: (Track_Resources when ODIN_TEST else struct {}),
}

// Watcher_File_Poll watches a single file by stat-based polling.
// The prev field holds the last known state inline (no extra allocation).
Watcher_File_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
	prev:      File_Info,
}

// Watcher_Dir_Poll watches a directory by snapshot-based polling.
// Allocates a map of file info snapshots, replaced each polling interval.
Watcher_Dir_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
	prev:      map[string]File_Info,
}

// Watcher_Recursive_Poll watches a directory recursively by snapshot-based polling.
// Allocates a map of file info snapshots covering all subdirectories.
Watcher_Recursive_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
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

// === Constructors — all heap-allocate, return pointers ===

// watch_file creates a native watcher for a single file.
// Initializes OS handles. Does NOT start a thread.
// Call get_events to receive events.
// Call destroy(w) when done.
watch_file :: proc(path: string, allocator := context.allocator) -> (^Watcher_File, Error) {

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
watch_dir :: proc(path: string, allocator := context.allocator) -> (^Watcher_Dir, Error) {

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
// Subdirectories created after init are auto-watched when the OS reports an
// .Added event for them on the next get_events call.
watch_dir_recursive :: proc(path: string, allocator := context.allocator) -> (^Watcher_Recursive, Error) {

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
// Each call performs a single stat() check; the user should sleep `latency`
// between calls (e.g. time.sleep(latency) in their loop).
watch_file_poll :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_File_Poll, Error) {

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
		latency   = latency,
		prev      = fi,
	}

	return w, .None
}

// watch_dir_poll creates a polling watcher for a directory.
// No thread is started. Each get_events call performs a single
// snapshot diff.
watch_dir_poll :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Dir_Poll, Error) {

	p, err := filepath.abs(path, allocator)
	if err != nil do return nil, .Invalid_Path

	prev := make(map[string]File_Info, allocator)
	snapshot_dir_alloc(p, &prev, allocator)

	w, new_err := new(Watcher_Dir_Poll, allocator)
	if new_err != nil do return nil, .Backend_Init_Failed

	w^ = Watcher_Dir_Poll{
		path      = p,
		allocator = allocator,
		latency   = latency,
		prev      = prev,
	}

	return w, .None
}

// watch_dir_poll_recursive creates a polling watcher for a directory tree.
// No thread is started. Each get_events call performs a single
// recursive snapshot diff.
watch_dir_poll_recursive :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Recursive_Poll, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	prev := make(map[string]File_Info, allocator)
	snapshot_recursive_alloc(p, &prev, allocator)
	w := new(Watcher_Recursive_Poll, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Recursive_Poll{
		path      = p,
		allocator = allocator,
		latency   = latency,
		prev      = prev,
	}
	return w, .None
}

// watch_glob creates a watcher that filters events through a glob pattern.
// The static prefix of the pattern is used as the watch root (e.g. "/tmp" from "/tmp/*.txt").
// The directory is watched recursively; only files matching the pattern trigger events.
// No thread is started. Performs an initial scan to detect pre-existing matching files.
watch_glob :: proc(pattern: string, allocator := context.allocator) -> (^Watcher_Glob, Error) {

	root, pat := glob_extract_root(pattern)
	p, err := filepath.abs(root, allocator)
	if err != nil do return nil, .Invalid_Path

	w := new(Watcher_Glob, allocator)
	if w == nil do return nil, .Backend_Init_Failed

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
destroy_file :: proc(w: ^Watcher_File) {
	if w == nil do return
	backend_file_destroy(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir stops and frees a Watcher_Dir. Safe to call with nil.
destroy_dir :: proc(w: ^Watcher_Dir) {
	if w == nil do return
	backend_dir_destroy(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_rec stops and frees a Watcher_Recursive. Safe to call with nil.
destroy_rec :: proc(w: ^Watcher_Recursive) {
	if w == nil do return
	backend_rec_destroy(w)
	backend_rec_native_cleanup(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_file_poll stops and frees a Watcher_File_Poll. Safe to call with nil.
destroy_file_poll :: proc(w: ^Watcher_File_Poll) {
	if w == nil do return
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir_poll stops and frees a Watcher_Dir_Poll. Safe to call with nil.
destroy_dir_poll :: proc(w: ^Watcher_Dir_Poll) {
	if w == nil do return
	for path in w.prev {
		delete(path, w.allocator)
	}
	delete(w.prev)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_rec_poll stops and frees a Watcher_Recursive_Poll. Safe to call with nil.
destroy_rec_poll :: proc(w: ^Watcher_Recursive_Poll) {
	if w == nil do return
	for path in w.prev {
		delete(path, w.allocator)
	}
	delete(w.prev)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_glob stops and frees a Watcher_Glob and its embedded recursive watcher. Safe to call with nil.
destroy_glob :: proc(w: ^Watcher_Glob) {
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
// Call destroy(w) with any ^Watcher_* to free it.
destroy :: proc {
	destroy_file,
	destroy_dir,
	destroy_rec,
	destroy_file_poll,
	destroy_dir_poll,
	destroy_rec_poll,
	destroy_glob,
}

// === get_events ===

// get_events_file returns all available events from a Watcher_File.
// The returned slice's backing array and the path strings inside are
// allocated with `allocator` (defaults to context.allocator).
// Pass context.temp_allocator if you don't plan to store the events.
// For native backends, performs a non-blocking read of the OS notification queue.
get_events_file :: proc(w: ^Watcher_File, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_file_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_dir returns all available events from a Watcher_Dir.
get_events_dir :: proc(w: ^Watcher_Dir, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_dir_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_rec returns all available events from a Watcher_Recursive.
get_events_rec :: proc(w: ^Watcher_Recursive, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	backend_rec_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

get_events_glob :: glob_get_events

// get_events_file_poll returns all available events from a Watcher_File_Poll.
get_events_file_poll :: proc(w: ^Watcher_File_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 4, allocator)
	poll_file_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_dir_poll returns all available events from a Watcher_Dir_Poll.
get_events_dir_poll :: proc(w: ^Watcher_Dir_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	poll_dir_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events_rec_poll returns all available events from a Watcher_Recursive_Poll.
get_events_rec_poll :: proc(w: ^Watcher_Recursive_Poll, allocator := context.allocator) -> []Event {
	events := make([dynamic]Event, 0, 16, allocator)
	poll_rec_get_events(w, allocator, &events)
	shrink(&events)
	return events[:]
}

// get_events is a procedure group that accepts any watcher type.
// Returns all available events from a single OS read / poll cycle.
// The returned [dynamic]Event must be `delete`d by the caller.
get_events :: proc {
	get_events_file,
	get_events_dir,
	get_events_rec,
	get_events_file_poll,
	get_events_dir_poll,
	get_events_rec_poll,
	get_events_glob,
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
rescan_rec :: proc(w: ^Watcher_Recursive) -> Error {
	return backend_rec_rescan(w)
}

// rescan_rec_poll forces a full rescan of a polling recursive watcher, rebuilding the snapshot.
rescan_rec_poll :: proc(w: ^Watcher_Recursive_Poll) -> Error {
	delete(w.prev)
	w.prev = make(map[string]File_Info, w.allocator)
	snapshot_recursive_alloc(w.path, &w.prev, w.allocator)
	return .None
}

// rescan_glob forces a full rescan of a glob watcher, re-registering watches and re-matching files.
rescan_glob :: proc(w: ^Watcher_Glob) -> Error {
	e := rescan_rec(&w.inner)
	if e != .None { return e }
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
}
