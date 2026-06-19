// fsw.odin — Main library file: watcher types, constructors, get_event/get_events, destroy, rescan.
//
// This is the primary entry point for the fsw library. It contains:
//   - watcher structs (Watcher_File, Watcher_Dir, Watcher_Recursive,
//                      Watcher_File_Poll, Watcher_Dir_Poll, Watcher_Recursive_Poll, Watcher_Glob)
//   - constructor procs (watch_file, watch_dir, watch_dir_recursive,
//                        watch_file_poll, watch_dir_poll, watch_dir_poll_recursive, watch_glob)
//   - get_event and get_events procedure groups (accept any watcher type)
//   - destroy procedure group (accepts any watcher type)
//   - rescan procedure group (for recursive and glob watchers)
//
// The library is pull-based: constructors create OS handles and prepare internal state
// but do NOT start threads. The user drives the event loop by calling get_event /
// get_events on a watcher. For polling watchers, each call performs a single diff cycle.

package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

// === Watcher types ===

// Watcher_File watches a single file using the OS-native backend.
Watcher_File :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_File, // platform-specific data (fd, inotify wd, kqueue ev, etc.)
	events:    [dynamic]Event,
}

// Watcher_Dir watches a directory (non-recursive) using the OS-native backend.
// Only immediate children are reported.
Watcher_Dir :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_Dir,
	events:    [dynamic]Event,
}

// Watcher_Recursive watches a directory and all its subdirectories.
// Allocates a map to track per-subdirectory watches. New subdirectories
// are automatically watched when detected. The user_data field is reserved
// for internal use by Watcher_Glob.
Watcher_Recursive :: struct {
	path:      string,
	allocator: mem.Allocator,
	native:    Native_Recursive,
	events:    [dynamic]Event,
}

// Watcher_File_Poll watches a single file by stat-based polling.
// The prev field holds the last known state inline (no extra allocation).
Watcher_File_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
	prev:      File_Info,
	events:    [dynamic]Event,
}

// Watcher_Dir_Poll watches a directory by snapshot-based polling.
// Allocates a map of file info snapshots, replaced each polling interval.
Watcher_Dir_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
	prev:      map[string]File_Info,
	events:    [dynamic]Event,
}

// Watcher_Recursive_Poll watches a directory recursively by snapshot-based polling.
// Allocates a map of file info snapshots covering all subdirectories.
Watcher_Recursive_Poll :: struct {
	path:      string,
	allocator: mem.Allocator,
	latency:   time.Duration,
	prev:      map[string]File_Info,
	events:    [dynamic]Event,
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
	events:        [dynamic]Event,
}

// === Constructors — all heap-allocate, return pointers ===

// watch_file creates a native watcher for a single file.
// Initializes OS handles. Does NOT start a thread.
// Call get_event or get_events to receive events.
// Call destroy(w) when done.
watch_file :: proc(path: string, allocator := context.allocator) -> (^Watcher_File, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_File, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_File{
		path      = p,
		allocator = allocator,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	e := backend_file_init(w)
	if e != .None {
		delete(w.events)
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
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Dir, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Dir{
		path      = p,
		allocator = allocator,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	e := backend_dir_init(w)
	if e != .None {
		delete(w.events)
		delete(w.path, allocator)
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

// watch_dir_recursive creates a native watcher for a directory tree.
// Initializes OS handles and registers all subdirectories. Does NOT start a thread.
// Subdirectories created after init are detected on the next get_event call
// (which rescans the tree).
watch_dir_recursive :: proc(path: string, allocator := context.allocator) -> (^Watcher_Recursive, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Recursive, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Recursive{
		path      = p,
		allocator = allocator,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	e := backend_rec_init(w)
	if e != .None {
		delete(w.events)
		delete(w.path, allocator)
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

// watch_file_poll creates a polling watcher for a single file.
// No thread is started. The user drives polling by calling get_event/get_events.
// Each call performs a single stat() check; the user should sleep `latency`
// between calls (e.g. time.sleep(latency) in their loop).
watch_file_poll :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_File_Poll, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	os_fi, stat_err := os.stat(p, allocator)
	if stat_err != nil {
		return nil, .Invalid_Path
	}
	defer os.file_info_delete(os_fi, allocator)
	fi := File_Info{
		is_dir = os_fi.type == .Directory,
		size   = os_fi.size,
		mtime  = os_fi.modification_time,
		inode  = os_fi.inode,
	}
	w := new(Watcher_File_Poll, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_File_Poll{
		path      = p,
		allocator = allocator,
		latency   = latency,
		prev      = fi,
		events    = make([dynamic]Event, 0, 4, allocator),
	}
	return w, .None
}

// watch_dir_poll creates a polling watcher for a directory.
// No thread is started. Each get_event/get_events call performs a single
// snapshot diff.
watch_dir_poll :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Dir_Poll, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	prev := make(map[string]File_Info, allocator)
	snapshot_dir(p, &prev, allocator)
	w := new(Watcher_Dir_Poll, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Dir_Poll{
		path      = p,
		allocator = allocator,
		latency   = latency,
		prev      = prev,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	return w, .None
}

// watch_dir_poll_recursive creates a polling watcher for a directory tree.
// No thread is started. Each get_event/get_events call performs a single
// recursive snapshot diff.
watch_dir_poll_recursive :: proc(path: string, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Recursive_Poll, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	prev := make(map[string]File_Info, allocator)
	snapshot_recursive(p, &prev, allocator)
	w := new(Watcher_Recursive_Poll, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Recursive_Poll{
		path      = p,
		allocator = allocator,
		latency   = latency,
		prev      = prev,
		events    = make([dynamic]Event, 0, 16, allocator),
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
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Glob, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Glob{
		pattern   = pat,
		allocator = allocator,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	w.inner = Watcher_Recursive{
		path      = p,
		allocator = allocator,
		events    = make([dynamic]Event, 0, 16, allocator),
	}
	e := backend_rec_init(&w.inner)
	if e != .None {
		delete(w.inner.events)
		delete(w.inner.path, allocator)
		delete(w.events)
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
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir stops and frees a Watcher_Dir. Safe to call with nil.
destroy_dir :: proc(w: ^Watcher_Dir) {
	if w == nil do return
	backend_dir_destroy(w)
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_rec stops and frees a Watcher_Recursive. Safe to call with nil.
destroy_rec :: proc(w: ^Watcher_Recursive) {
	if w == nil do return
	backend_rec_destroy(w)
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
	for _, v in w.native.watches {
		delete(v, w.allocator)
	}
	delete(w.native.watches)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_file_poll stops and frees a Watcher_File_Poll. Safe to call with nil.
destroy_file_poll :: proc(w: ^Watcher_File_Poll) {
	if w == nil do return
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

// destroy_dir_poll stops and frees a Watcher_Dir_Poll. Safe to call with nil.
destroy_dir_poll :: proc(w: ^Watcher_Dir_Poll) {
	if w == nil do return
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
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
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
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
	for e in w.events {
		delete(e.path, w.allocator)
	}
	delete(w.events)
	for e in w.inner.events {
		delete(e.path, w.allocator)
	}
	delete(w.inner.events)
	for _, v in w.inner.native.watches {
		delete(v, w.allocator)
	}
	delete(w.inner.native.watches)
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

// === get_event / get_events ===

// get_event_file returns the next event from a Watcher_File.
// The returned Event's path is valid until the next call to get_event/get_events
// or until destroy. Returns false when no events are available (try again later).
// For native backends, performs a non-blocking read of the OS notification queue.
get_event_file :: proc(w: ^Watcher_File) -> (Event, bool) {
	return backend_file_get_event(w)
}

// get_event_dir returns the next event from a Watcher_Dir.
get_event_dir :: proc(w: ^Watcher_Dir) -> (Event, bool) {
	return backend_dir_get_event(w)
}

// get_event_rec returns the next event from a Watcher_Recursive.
get_event_rec :: proc(w: ^Watcher_Recursive) -> (Event, bool) {
	return backend_rec_get_event(w)
}

// get_event_file_poll returns the next event from a Watcher_File_Poll.
// (Implementation in backend_poll.odin.)

// get_event_dir_poll returns the next event from a Watcher_Dir_Poll.
// (Implementation in backend_poll.odin.)

// get_event_rec_poll returns the next event from a Watcher_Recursive_Poll.
// (Implementation in backend_poll.odin.)

// get_event_glob returns the next event from a Watcher_Glob.
// Internally calls get_event on the embedded recursive watcher and filters
// through the glob pattern.
get_event_glob :: proc(w: ^Watcher_Glob) -> (Event, bool) {
	return glob_get_event(w)
}

// get_event is a procedure group that accepts any watcher type.
// Returns the next event, or false if no events are available.
get_event :: proc {
	get_event_file,
	get_event_dir,
	get_event_rec,
	get_event_file_poll,
	get_event_dir_poll,
	get_event_rec_poll,
	get_event_glob,
}

// get_events_file returns all available events from a Watcher_File.
// Drains the OS notification queue into a fresh slice.
// The returned slice's events are valid until the next call to get_event/get_events
// or until destroy. The user must clone paths if they want to keep them past that.
get_events_file :: proc(w: ^Watcher_File) -> []Event {
	return backend_file_get_events(w)
}

// get_events_dir returns all available events from a Watcher_Dir.
get_events_dir :: proc(w: ^Watcher_Dir) -> []Event {
	return backend_dir_get_events(w)
}

// get_events_rec returns all available events from a Watcher_Recursive.
get_events_rec :: proc(w: ^Watcher_Recursive) -> []Event {
	return backend_rec_get_events(w)
}

// get_events_file_poll returns all available events from a Watcher_File_Poll.
// (Implementation in backend_poll.odin.)

// get_events_dir_poll returns all available events from a Watcher_Dir_Poll.
// (Implementation in backend_poll.odin.)

// get_events_rec_poll returns all available events from a Watcher_Recursive_Poll.
// (Implementation in backend_poll.odin.)

// get_events_glob returns all available events from a Watcher_Glob.
get_events_glob :: proc(w: ^Watcher_Glob) -> []Event {
	return glob_get_events(w)
}

// get_events is a procedure group that accepts any watcher type.
// Returns all available events from a single OS read / poll cycle.
get_events :: proc {
	get_events_file,
	get_events_dir,
	get_events_rec,
	get_events_file_poll,
	get_events_dir_poll,
	get_events_rec_poll,
	get_events_glob,
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
	snapshot_recursive(w.path, &w.prev, w.allocator)
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
