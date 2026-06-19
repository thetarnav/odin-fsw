// backend_darwin.odin — macOS backend using kqueue + EVFILT_VNODE.
//
// Platform-specific backend compiled only on macOS.
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.
//
// Pull-based architecture:
//   - Each watcher opens the target with os.open() to get a file descriptor
//   - A kqueue is created and EVFILT_VNODE kevents are registered with
//     {.Delete, .Write, .Extend, .Attrib, .Link, .Rename} flags
//   - backend_*_get_event(s) procs do a non-blocking kevent() call (NULL timeout)
//   - For dir/rec watchers, each call also does a snapshot diff since kqueue
//     VNode events don't catch file content changes
//   - Recursive watcher: per-subdirectory fd registration, storing fd→dir_path
//     in w.native.watches. New subdirs are auto-watched on detection.

package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"

// === Platform-specific native data ===
// The Native_* structs hold the kqueue fd, the open file fd, and (for
// dir/recursive) snapshot state for diffing.

Native_File :: struct {
	kq:   posix.FD, // kqueue fd
	fd:   int,      // file descriptor of the open target
	file: ^os.File, // os.File handle
}

Native_Dir :: struct {
	kq:   posix.FD,
	fd:   int,
	file: ^os.File,
	prev: map[string]File_Info, // snapshot keyed by entry name
}

Native_Recursive :: struct {
	kq:      posix.FD,
	watches: map[int]string,                   // fd -> dir_path
	prev:    map[string]map[string]File_Info,  // dir_path -> {entry_name -> File_Info}
}

kq_normalize :: proc(fflags: kqueue.VNode_Flags) -> Event_Kind {
	if .Delete in fflags || .Revoke in fflags { return .Removed }
	if .Rename in fflags { return .Renamed }
	if .Write in fflags || .Extend in fflags { return .Modified }
	if .Attrib in fflags || .Link in fflags { return .Modified }
	return .Modified
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	file, err := os.open(w.path, os.O_RDONLY)
	if err != nil { return .Backend_Init_Failed }

	kq, errno := kqueue.kqueue()
	if errno != .NONE {
		os.close(file)
		return .Backend_Init_Failed
	}

	fd := int(os.fd(file))
	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno2 := kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE {
		posix.close(kq)
		os.close(file)
		return .Backend_Init_Failed
	}

	w.native.kq = kq
	w.native.fd = fd
	w.native.file = file
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	posix.close(w.native.kq)
	os.close(w.native.file)
}

backend_file_get_event :: proc(w: ^Watcher_File) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return kqueue_read_file(w, &w.events, w.allocator, false)
}

backend_file_get_events :: proc(w: ^Watcher_File) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = kqueue_read_file(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	file, err := os.open(w.path, os.O_RDONLY)
	if err != nil { return .Backend_Init_Failed }

	kq, errno := kqueue.kqueue()
	if errno != .NONE {
		os.close(file)
		return .Backend_Init_Failed
	}

	fd := int(os.fd(file))
	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno2 := kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE {
		posix.close(kq)
		os.close(file)
		return .Backend_Init_Failed
	}

	w.native.kq = kq
	w.native.fd = fd
	w.native.file = file
	w.native.prev = make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name_alloc(w.path, &w.native.prev, w.allocator)
	fmt.eprintf("  [debug] dir_init done: kq=%v fd=%d prev keys=%d\n", int(kq), fd, len(w.native.prev))
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	posix.close(w.native.kq)
	os.close(w.native.file)
	for k in w.native.prev { delete(k, w.allocator) }
	delete(w.native.prev)
}

backend_dir_get_event :: proc(w: ^Watcher_Dir) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return kqueue_read_dir(w, &w.events, w.allocator, false)
}

backend_dir_get_events :: proc(w: ^Watcher_Dir) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = kqueue_read_dir(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	kq, errno := kqueue.kqueue()
	if errno != .NONE { return .Backend_Init_Failed }
	w.native.kq = kq
	w.native.watches = make(map[int]string, w.allocator)
	w.native.prev = make(map[string]map[string]File_Info, w.allocator)
	darwin_rec_add_watch(w, w.path)
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	posix.close(w.native.kq)
	for fd_key in w.native.watches {
		posix.close(posix.FD(fd_key))
	}
}

backend_rec_native_cleanup :: proc(w: ^Watcher_Recursive) {
	for _, v in w.native.watches {
		delete(v, w.allocator)
	}
	delete(w.native.watches)
	for _, inner in w.native.prev {
		for k in inner {
			delete(k, w.allocator)
		}
		delete(inner)
	}
	delete(w.native.prev)
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	for fd_key in w.native.watches {
		posix.close(posix.FD(fd_key))
	}
	for _, v in w.native.watches { delete(v, w.allocator) }
	clear(&w.native.watches)
	for _, inner in w.native.prev {
		for k in inner { delete(k, w.allocator) }
		delete(inner)
	}
	clear(&w.native.prev)
	darwin_rec_add_watch(w, w.path)
	return .None
}

darwin_rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	file, err := os.open(dir, os.O_RDONLY)
	if err != nil do return
	fd := int(os.fd(file))

	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno := kqueue.kevent(w.native.kq, []kqueue.KEvent{ev}, nil, nil)
	if errno != .NONE {
		os.close(file)
		return
	}

	w.native.watches[fd] = strings.clone(dir, w.allocator)

	dir_prev := make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name_alloc(dir, &dir_prev, w.allocator)
	w.native.prev[dir] = dir_prev

	entries, read_err := os.read_all_directory_by_path(dir, w.allocator)
	if read_err != nil do return
	defer {
		for entry in entries {
			os.file_info_delete(entry, w.allocator)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		if entry.type == .Directory {
			subdir := filepath.join({dir, entry.name}, w.allocator) or_continue
			darwin_rec_add_watch(w, subdir)
		}
	}
}

backend_rec_get_event :: proc(w: ^Watcher_Recursive) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return kqueue_read_rec(w, &w.events, w.allocator, false)
}

backend_rec_get_events :: proc(w: ^Watcher_Recursive) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = kqueue_read_rec(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Shared kqueue read helpers ===

@(private)
kqueue_read_file :: proc(w: ^Watcher_File, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	events: [1]kqueue.KEvent
	got_one: bool
	for {
		n, _ := kqueue.kevent(w.native.kq, nil, events[:], nil)
		if n <= 0 do break
		ev := events[0]
		if ev.filter == .VNode {
			fflags := ev.fflags.vnode
			if fflags != {} {
				kind := kq_normalize(fflags)
				e := Event{kind = kind, path = strings.clone(w.path, allocator)}
				if drain {
					append(out, e)
					got_one = true
				} else {
					return e, true
				}
			}
		}
		if !drain do break
	}
	if !drain do return {}, false
	return {}, got_one
}

// dir_diff fills `out` with the snapshot diff events for a Watcher_Dir.
// Replaces w.native.prev with the new snapshot.
@(private)
dir_diff :: proc(w: ^Watcher_Dir, out: ^[dynamic]Event, allocator: mem.Allocator) {
	old := w.native.prev
	current := make(map[string]File_Info, allocator)
	snapshot_dir_by_name_alloc(w.path, &current, allocator)

	for name in old {
		if _, ok := current[name]; !ok {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			append(out, Event{kind = .Removed, path = fullpath})
		}
	}
	for name, fi in current {
		prev, ok := old[name]
		if !ok {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			append(out, Event{kind = .Added, path = fullpath, is_dir = fi.is_dir})
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			append(out, Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir})
		}
	}

	// Free old keys and replace prev
	for k in old { delete(k, allocator) }
	delete(old)
	w.native.prev = current
}

@(private)
kqueue_read_dir :: proc(w: ^Watcher_Dir, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	// Drain kqueue (kqueue VNode catches some events but not content changes)
	events: [1]kqueue.KEvent
	_, _ = kqueue.kevent(w.native.kq, nil, events[:], nil)

	// Save state in case we need to abort and restore
	old := w.native.prev
	current := make(map[string]File_Info, allocator)
	snapshot_dir_by_name_alloc(w.path, &current, allocator)

	got_one: bool
	for name in old {
		if _, ok := current[name]; !ok {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			e := Event{kind = .Removed, path = fullpath}
			if drain {
				append(out, e)
				got_one = true
			} else {
				// Abort: free new keys, restore old
				for k in current { delete(k, allocator) }
				delete(current)
				return e, true
			}
		}
	}
	for name, fi in current {
		prev, ok := old[name]
		if !ok {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			e := Event{kind = .Added, path = fullpath, is_dir = fi.is_dir}
			if drain {
				append(out, e)
				got_one = true
			} else {
				for k in current { delete(k, allocator) }
				delete(current)
				return e, true
			}
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			fullpath := filepath.join({w.path, name}, allocator) or_continue
			e := Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir}
			if drain {
				append(out, e)
				got_one = true
			} else {
				for k in current { delete(k, allocator) }
				delete(current)
				return e, true
			}
		}
	}

	// Commit: free old, install new
	for k in old { delete(k, allocator) }
	delete(old)
	w.native.prev = current

	if !drain do return {}, false
	if got_one do return {}, true
	return {}, false
}

// rec_diff fills `out` with the snapshot diff events for all watched dirs in a
// Watcher_Recursive. Replaces w.native.prev[dir] with the new snapshot for
// each dir.
@(private)
rec_diff :: proc(w: ^Watcher_Recursive, out: ^[dynamic]Event, allocator: mem.Allocator) {
	for dir_path, dir_prev in w.native.prev {
		current := make(map[string]File_Info, allocator)
		snapshot_dir_by_name_alloc(dir_path, &current, allocator)

		for name in dir_prev {
			if _, ok := current[name]; !ok {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				append(out, Event{kind = .Removed, path = fullpath})
			}
		}
		for name, fi in current {
			prev_fi, ok := dir_prev[name]
			if !ok {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				// Auto-watch new subdirs BEFORE emitting event to avoid race
				if fi.is_dir {
					darwin_rec_add_watch(w, fullpath)
				}
				append(out, Event{kind = .Added, path = fullpath, is_dir = fi.is_dir})
			} else if fi.mtime != prev_fi.mtime || fi.size != prev_fi.size {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				append(out, Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir})
			}
		}

		for k in dir_prev { delete(k, allocator) }
		delete(dir_prev)
		w.native.prev[dir_path] = current
	}
}

@(private)
kqueue_read_rec :: proc(w: ^Watcher_Recursive, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	// Drain kqueue
	events: [64]kqueue.KEvent
	_, _ = kqueue.kevent(w.native.kq, nil, events[:], nil)

	// Snapshot diff for all watched dirs
	got_one: bool
	first_event: Event
	for dir_path, dir_prev in w.native.prev {
		current := make(map[string]File_Info, allocator)
		snapshot_dir_by_name_alloc(dir_path, &current, allocator)

		dir_had_event := false
		for name in dir_prev {
			if _, ok := current[name]; !ok {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				e := Event{kind = .Removed, path = fullpath}
				if drain {
					append(out, e)
					got_one = true
					dir_had_event = true
				} else if !got_one {
					first_event = e
					got_one = true
				}
			}
		}
		for name, fi in current {
			prev_fi, ok := dir_prev[name]
			if !ok {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				if fi.is_dir {
					darwin_rec_add_watch(w, fullpath)
				}
				e := Event{kind = .Added, path = fullpath, is_dir = fi.is_dir}
				if drain {
					append(out, e)
					got_one = true
					dir_had_event = true
				} else if !got_one {
					first_event = e
					got_one = true
				}
			} else if fi.mtime != prev_fi.mtime || fi.size != prev_fi.size {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				e := Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir}
				if drain {
					append(out, e)
					got_one = true
					dir_had_event = true
				} else if !got_one {
					first_event = e
					got_one = true
				}
			}
		}

		// Always commit the new snapshot for this dir (we've already done the read)
		_ = dir_had_event
		for k in dir_prev { delete(k, allocator) }
		delete(dir_prev)
		w.native.prev[dir_path] = current
	}

	if drain {
		if got_one do return {}, true
		return {}, false
	}
	if got_one {
		return first_event, true
	}
	return {}, false
}
