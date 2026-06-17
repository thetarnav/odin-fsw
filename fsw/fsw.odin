package fsw

import "base:runtime"
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
	caller_ctx:    runtime.Context,
	allocator:     mem.Allocator,
}

// Non-recursive directory — native.
Watcher_Dir :: struct {
	callback:      Event_Callback,
	path:          string,
	running:       bool,
	native_handle: int,
	thread:        ^thread.Thread,
	caller_ctx:    runtime.Context,
	allocator:     mem.Allocator,
}

// Recursive directory — native. Allocates map.
Watcher_Recursive :: struct {
	callback:    Event_Callback,
	path:        string,
	running:     bool,
	native_handle: int,
	watches:       map[int]string,
	thread:        ^thread.Thread,
	user_data:     rawptr,
	caller_ctx:    runtime.Context,
	allocator:     mem.Allocator,
}

// Single file — polling. Inline snapshot.
Watcher_File_Poll :: struct {
	callback:   Event_Callback,
	path:       string,
	running:    bool,
	latency:    time.Duration,
	prev:       File_Info,
	thread:     ^thread.Thread,
	caller_ctx: runtime.Context,
	allocator:  mem.Allocator,
}

// Non-recursive directory — polling. Allocates file map.
Watcher_Dir_Poll :: struct {
	callback:   Event_Callback,
	path:       string,
	running:    bool,
	latency:    time.Duration,
	prev:       map[string]File_Info,
	thread:     ^thread.Thread,
	caller_ctx: runtime.Context,
	allocator:  mem.Allocator,
}

// Recursive directory — polling. Allocates file map + subdir tracking.
Watcher_Recursive_Poll :: struct {
	callback:   Event_Callback,
	path:       string,
	running:    bool,
	latency:    time.Duration,
	prev:       map[string]File_Info,
	thread:     ^thread.Thread,
	caller_ctx: runtime.Context,
	allocator:  mem.Allocator,
}

// Glob — watches directory recursively, filters by glob pattern.
Watcher_Glob :: struct {
	callback:      Event_Callback,
	pattern:       string,
	running:       bool,
	matched_files: map[string]bool,
	inner:         Watcher_Recursive,
	caller_ctx:    runtime.Context,
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

// === Context-restoring callback invocation ===
// Threads don't inherit the caller's context. Each watcher saves
// the caller's context at construction time. These helpers restore
// it before invoking the user callback.

invoke_callback_file :: proc(w: ^Watcher_File, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_dir :: proc(w: ^Watcher_Dir, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_rec :: proc(w: ^Watcher_Recursive, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_file_poll :: proc(w: ^Watcher_File_Poll, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_dir_poll :: proc(w: ^Watcher_Dir_Poll, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_rec_poll :: proc(w: ^Watcher_Recursive_Poll, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}
invoke_callback_glob :: proc(w: ^Watcher_Glob, e: ^Event) {
	context = w.caller_ctx
	w.callback(e)
}

// === Constructors — all heap-allocate, return pointers ===

watch_file :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_File, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_File, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_File{
		callback    = cb,
		path        = p,
		running     = true,
		caller_ctx  = context,
		allocator   = allocator,
	}
	e := backend_file_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_dir :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Dir, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Dir, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Dir{
		callback    = cb,
		path        = p,
		running     = true,
		caller_ctx  = context,
		allocator   = allocator,
	}
	e := backend_dir_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_dir_recursive :: proc(path: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Recursive, Error) {
	p, err := filepath.abs(path, allocator)
	if err != nil {
		return nil, .Invalid_Path
	}
	w := new(Watcher_Recursive, allocator)
	if w == nil {
		return nil, .Backend_Init_Failed
	}
	w^ = Watcher_Recursive{
		callback    = cb,
		path        = p,
		running     = true,
		caller_ctx  = context,
		allocator   = allocator,
	}
	e := backend_rec_init(w)
	if e != .None {
		free(w, allocator)
		return nil, e
	}
	return w, .None
}

watch_file_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_File_Poll, Error) {
	p, err := filepath.abs(path, allocator)
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
		callback    = cb,
		path        = p,
		running     = true,
		latency     = latency,
		prev        = fi,
		caller_ctx  = context,
		allocator   = allocator,
	}
	w.thread = start_poll_file_thread(w)
	return w, .None
}

watch_dir_poll :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Dir_Poll, Error) {
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
		callback    = cb,
		path        = p,
		running     = true,
		latency     = latency,
		prev        = prev,
		caller_ctx  = context,
		allocator   = allocator,
	}
	w.thread = start_poll_dir_thread(w)
	return w, .None
}

watch_dir_poll_recursive :: proc(path: string, cb: Event_Callback, latency: time.Duration, allocator := context.allocator) -> (^Watcher_Recursive_Poll, Error) {
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
		callback    = cb,
		path        = p,
		running     = true,
		latency     = latency,
		prev        = prev,
		caller_ctx  = context,
		allocator   = allocator,
	}
	w.thread = start_poll_rec_thread(w)
	return w, .None
}

watch_glob :: proc(pattern: string, cb: Event_Callback, allocator := context.allocator) -> (^Watcher_Glob, Error) {
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
		callback    = cb,
		pattern     = pat,
		running     = true,
		caller_ctx  = context,
		allocator   = allocator,
	}
	w.inner = Watcher_Recursive{
		callback    = glob_inner_callback,
		path        = p,
		running     = true,
		user_data   = rawptr(w),
		caller_ctx  = context,
		allocator   = allocator,
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
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

destroy_dir :: proc(w: ^Watcher_Dir) {
	if w == nil || !w.running { return }
	w.running = false
	backend_dir_destroy(w)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

destroy_rec :: proc(w: ^Watcher_Recursive) {
	if w == nil || !w.running { return }
	w.running = false
	backend_rec_destroy(w)
	for _, v in w.watches {
		delete(v, w.allocator)
	}
	delete(w.watches)
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

destroy_file_poll :: proc(w: ^Watcher_File_Poll) {
	if w == nil || !w.running { return }
	w.running = false
	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	delete(w.path, w.allocator)
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
	delete(w.path, w.allocator)
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
	delete(w.path, w.allocator)
	free(w, w.allocator)
}

destroy_glob :: proc(w: ^Watcher_Glob) {
	if w == nil || !w.running { return }
	w.running = false
	w.inner.running = false
	backend_rec_destroy(&w.inner)
    delete(w.inner.path)
	for _, v in w.inner.watches {
		delete(v, w.allocator)
	}
	delete(w.inner.watches)
	for path in w.matched_files {
		delete(path, w.allocator)
	}
	delete(w.matched_files)
	free(w, w.allocator)
}

destroy_watcher :: proc(w: ^Watcher) {
	if w == nil do return
    switch v in w {
    case ^Watcher_File:           destroy_file(v)
    case ^Watcher_Dir:            destroy_dir(v)
    case ^Watcher_Recursive:      destroy_rec(v)
    case ^Watcher_File_Poll:      destroy_file_poll(v)
    case ^Watcher_Dir_Poll:       destroy_dir_poll(v)
    case ^Watcher_Recursive_Poll: destroy_rec_poll(v)
    case ^Watcher_Glob:           destroy_glob(v)
    }
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
	if w == nil do return .Invalid_Path
    #partial switch v in w {
    case ^Watcher_Recursive:      return rescan_rec(v)
    case ^Watcher_Recursive_Poll: return rescan_rec_poll(v)
    case ^Watcher_Glob:           return rescan_glob(v)
    }
	return .None
}

rescan :: proc {
	rescan_rec,
	rescan_rec_poll,
	rescan_glob,
	rescan_watcher,
}

