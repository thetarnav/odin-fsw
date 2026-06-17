package fsw

import "core:mem"
import "core:path/filepath"
import "core:thread"
import "core:time"

// === Watcher types ===

// Single file — native.
Watcher_File :: struct {
	callback:      Event_Callback,
	path:          string,
	running:       bool,
	native_handle: int,
	thread:        ^thread.Thread,
	allocator:     mem.Allocator,
}

// Non-recursive directory — native.
Watcher_Dir :: struct {
	callback:      Event_Callback,
	path:          string,
	running:       bool,
	native_handle: int,
	thread:        ^thread.Thread,
	allocator:     mem.Allocator,
}

// Recursive directory — native. Allocates map.
Watcher_Recursive :: struct {
	callback:      Event_Callback,
	path:          string,
	running:       bool,
	native_handle: int,
	watches:       map[int]string,
	thread:        ^thread.Thread,
	user_data:     rawptr,
	allocator:     mem.Allocator,
}

// Single file — polling. Inline snapshot.
Watcher_File_Poll :: struct {
	callback:  Event_Callback,
	path:      string,
	running:   bool,
	latency:   time.Duration,
	prev:      File_Info,
	thread:    ^thread.Thread,
	allocator: mem.Allocator,
}

// Non-recursive directory — polling. Allocates file map.
Watcher_Dir_Poll :: struct {
	callback:  Event_Callback,
	path:      string,
	running:   bool,
	latency:   time.Duration,
	prev:      map[string]File_Info,
	thread:    ^thread.Thread,
	allocator: mem.Allocator,
}

// Recursive directory — polling. Allocates file map + subdir tracking.
Watcher_Recursive_Poll :: struct {
	callback:  Event_Callback,
	path:      string,
	running:   bool,
	latency:   time.Duration,
	prev:      map[string]File_Info,
	thread:    ^thread.Thread,
	allocator: mem.Allocator,
}

// Glob — watches directory recursively, filters by glob pattern.
Watcher_Glob :: struct {
	callback:      Event_Callback,
	pattern:       string,
	running:       bool,
	matched_files: map[string]bool,
	inner:         Watcher_Recursive,
	allocator:     mem.Allocator,
}

// === Union ===

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

watch_file :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_File, Error) {
	p, err := filepath.abs(path)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_File, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_File{
		callback  = cb,
		path      = p,
		running   = true,
		allocator = allocator,
	}
	e := backend_file_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_dir :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Dir, Error) {
	p, err := filepath.abs(path)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Dir, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Dir{
		callback  = cb,
		path      = p,
		running   = true,
		allocator = allocator,
	}
	e := backend_dir_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_dir_recursive :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Recursive, Error) {
	p, err := filepath.abs(path)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Recursive, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Recursive{
		callback  = cb,
		path      = p,
		running   = true,
		allocator = allocator,
	}
	e := backend_rec_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_file_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_File_Poll, Error) {
	p, err := filepath.abs(path)
	if err != nil {
		return nil, .Invalid_Path
	}
	fi, stat_err := file_stat(p)
	if stat_err != .None {
		return nil, .Invalid_Path
	}
	w := new(Watcher_File_Poll, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_File_Poll{
		callback  = cb,
		path      = p,
		running   = true,
		latency   = latency,
		prev      = fi,
		allocator = allocator,
	}
	w.thread = start_poll_file_thread(w)
	return w, .None
}

watch_dir_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Dir_Poll, Error) {
	p, err := filepath.abs(path)
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
		callback  = cb,
		path      = p,
		running   = true,
		latency   = latency,
		prev      = prev,
		allocator = allocator,
	}
	w.thread = start_poll_dir_thread(w)
	return w, .None
}

watch_dir_poll_recursive :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Recursive_Poll, Error) {
	p, err := filepath.abs(path)
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
		callback  = cb,
		path      = p,
		running   = true,
		latency   = latency,
		prev      = prev,
		allocator = allocator,
	}
	w.thread = start_poll_rec_thread(w)
	return w, .None
}

watch_glob :: proc(pattern: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Glob, Error) {
	root, pat := glob_extract_root(pattern)
	p, err := filepath.abs(root)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Glob, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Glob{
		callback  = cb,
		pattern   = pat,
		allocator = allocator,
	}
	w.inner = Watcher_Recursive{
		callback  = glob_inner_callback,
		path      = p,
		running   = true,
		user_data = rawptr(w),
		allocator = allocator,
	}
	e := backend_rec_init(&w.inner)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	w.matched_files = make(map[string]bool, allocator)
	glob_initial_scan(w)
	return w, .None
}

// === destroy ===

destroy_file :: proc(w: ^Watcher_File) {
	if w == nil || !w.running { return }
	w.running = false
	backend_file_destroy(w)
	free(w, w.allocator)
}

destroy_dir :: proc(w: ^Watcher_Dir) {
	if w == nil || !w.running { return }
	w.running = false
	backend_dir_destroy(w)
	free(w, w.allocator)
}

destroy_rec :: proc(w: ^Watcher_Recursive) {
	if w == nil || !w.running { return }
	w.running = false
	backend_rec_destroy(w)
	delete(w.watches)
	free(w, w.allocator)
}

destroy_file_poll :: proc(w: ^Watcher_File_Poll) {
	if w == nil || !w.running { return }
	w.running = false
	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	free(w, w.allocator)
}

destroy_dir_poll :: proc(w: ^Watcher_Dir_Poll) {
	if w == nil || !w.running { return }
	w.running = false
	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	delete(w.prev)
	free(w, w.allocator)
}

destroy_rec_poll :: proc(w: ^Watcher_Recursive_Poll) {
	if w == nil || !w.running { return }
	w.running = false
	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	delete(w.prev)
	free(w, w.allocator)
}

destroy_glob :: proc(w: ^Watcher_Glob) {
	if w == nil || !w.running { return }
	w.running = false
	// Clean up inner watcher directly (it's embedded, not separately allocated)
	w.inner.running = false
	backend_rec_destroy(&w.inner)
	delete(w.inner.watches)
	delete(w.matched_files)
	free(w, w.allocator)
}

destroy_watcher :: proc(w: ^Watcher) {
	if w == nil { return }
	if v, ok := w^.(^Watcher_File); ok { destroy_file(v); return }
	if v, ok := w^.(^Watcher_Dir); ok { destroy_dir(v); return }
	if v, ok := w^.(^Watcher_Recursive); ok { destroy_rec(v); return }
	if v, ok := w^.(^Watcher_File_Poll); ok { destroy_file_poll(v); return }
	if v, ok := w^.(^Watcher_Dir_Poll); ok { destroy_dir_poll(v); return }
	if v, ok := w^.(^Watcher_Recursive_Poll); ok { destroy_rec_poll(v); return }
	if v, ok := w^.(^Watcher_Glob); ok { destroy_glob(v); return }
}

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

// === rescan ===

rescan_rec :: proc(w: ^Watcher_Recursive) -> Error {
	return backend_rec_rescan(w)
}

rescan_rec_poll :: proc(w: ^Watcher_Recursive_Poll) -> Error {
	delete(w.prev)
	w.prev = make(map[string]File_Info, w.allocator)
	snapshot_recursive(w.path, &w.prev, w.allocator)
	return .None
}

rescan_glob :: proc(w: ^Watcher_Glob) -> Error {
	e := rescan_rec(&w.inner)
	if e != .None { return e }
	glob_rescan(w)
	return .None
}

rescan_watcher :: proc(w: ^Watcher) -> Error {
	if w == nil { return .Invalid_Path }
	if v, ok := w^.(^Watcher_Recursive); ok { return rescan_rec(v) }
	if v, ok := w^.(^Watcher_Recursive_Poll); ok { return rescan_rec_poll(v) }
	if v, ok := w^.(^Watcher_Glob); ok { return rescan_glob(v) }
	return .None
}

rescan :: proc {
	rescan_rec,
	rescan_rec_poll,
	rescan_glob,
	rescan_watcher,
}

// === Casting helpers ===

as_watcher_file :: proc(w: ^Watcher_File)           -> Watcher { return w }
as_watcher_dir :: proc(w: ^Watcher_Dir)             -> Watcher { return w }
as_watcher_rec :: proc(w: ^Watcher_Recursive)       -> Watcher { return w }
as_watcher_file_poll :: proc(w: ^Watcher_File_Poll) -> Watcher { return w }
as_watcher_dir_poll :: proc(w: ^Watcher_Dir_Poll)   -> Watcher { return w }
as_watcher_rec_poll :: proc(w: ^Watcher_Recursive_Poll) -> Watcher { return w }
as_watcher_glob :: proc(w: ^Watcher_Glob)           -> Watcher { return w }

as_watcher :: proc {
	as_watcher_file,
	as_watcher_dir,
	as_watcher_rec,
	as_watcher_file_poll,
	as_watcher_dir_poll,
	as_watcher_rec_poll,
	as_watcher_glob,
}
