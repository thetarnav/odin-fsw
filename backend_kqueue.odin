// backend_kqueue.odin — kqueue backend for Darwin, FreeBSD, NetBSD, OpenBSD.
//
// Uses kqueue with EVFILT_VNODE watches. Pull-based: each get_events call
// does a non-blocking kevent() read and a snapshot diff, appending all
// events to the caller's dynamic array.
//
//   - Watcher_File: kqueue VNode watch on the file
//   - Watcher_Dir:  kqueue VNode watch + snapshot diff for content changes
//   - Watcher_Recursive: per-subdirectory fd registration with kqueue + snapshot diff

#+build darwin, netbsd, openbsd, freebsd
package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"

Native_File :: struct {
	kq:   posix.FD,
	file: ^os.File,
}

Native_Dir :: struct {
	kq:   posix.FD,
	file: ^os.File,
	prev: map[string]File_Info,
}

Native_Recursive :: struct {
	kq:      posix.FD,
	watches: map[int]string,
	prev:    map[string]map[string]File_Info,
}

kq_normalize :: proc(fflags: kqueue.VNode_Flags) -> Event_Kind {
	if .Delete in fflags || .Revoke in fflags { return .Removed }
	if .Rename in fflags { return .Renamed }
	if .Write in fflags || .Extend in fflags { return .Modified }
	if .Attrib in fflags || .Link in fflags { return .Modified }
	return .Modified
}

// Zero timespec: passed to kevent so it returns immediately instead of
// waiting forever (which is what nil timeout means on macOS).
@(private, rodata)
no_wait: posix.timespec

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> (err: Error) {

	track_start(w)

	file, os_err := os.open(w.path, os.O_RDONLY)
	if os_err != nil do return .Backend_Init_Failed
	track_open(w, uintptr(file))
	defer if err != nil {
		os.close(file)
		track_close(w, uintptr(file))
	}

	kq, errno := kqueue.kqueue()
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, kq)
	defer if err != nil {
		posix.close(kq)
		track_close(w, kq)
	}

	ev := kqueue.KEvent{
		ident  = uintptr(os.fd(file)),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno2 := kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE do return .Backend_Init_Failed

	w.native.kq   = kq
	w.native.file = file

	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	posix.close(w.native.kq)
	track_close(w, w.native.kq)
	os.close(w.native.file)
	track_close(w, uintptr(w.native.file))
	track_end(w)
}

backend_file_get_events :: proc(w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	kqueue_drain_file(w, allocator, out)
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> (err: Error) {

	track_start(w)

	file, os_err := os.open(w.path, os.O_RDONLY)
	if os_err != nil do return .Backend_Init_Failed
	track_open(w, uintptr(file))
	defer if err != nil {
		os.close(file)
		track_close(w, uintptr(file))
	}

	kq, errno := kqueue.kqueue()
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, kq)
	defer if err != nil {
		posix.close(kq)
		track_close(w, kq)
	}

	ev := kqueue.KEvent{
		ident  = uintptr(os.fd(file)),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno2 := kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE do return .Backend_Init_Failed

	w.native.kq   = kq
	w.native.file = file
	w.native.prev = make(map[string]File_Info, w.allocator)

	snapshot_dir_by_name_alloc(w.path, &w.native.prev, w.allocator)

	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	posix.close(w.native.kq)
	track_close(w, w.native.kq)
	os.close(w.native.file)
	track_close(w, uintptr(w.native.file))
	for k in w.native.prev do delete(k, w.allocator)
	delete(w.native.prev)
	track_end(w)
}

backend_dir_get_events :: proc(w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	kqueue_drain_dir(w, allocator, out)
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {

	track_start(w)

	kq, errno := kqueue.kqueue()
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, kq)

	w.native.kq      = kq
	w.native.watches = make(map[int]string, w.allocator)
	w.native.prev    = make(map[string]map[string]File_Info, w.allocator)

	kqueue_rec_add_watch(w, w.path)

	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	posix.close(w.native.kq)
	track_close(w, w.native.kq)
	for fd_key in w.native.watches {
		posix.close(posix.FD(fd_key))
		track_close(w, fd_key)
	}
	track_end(w)
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
		track_close(w, fd_key)
	}
	for _, v in w.native.watches do delete(v, w.allocator)
	clear(&w.native.watches)
	for _, inner in w.native.prev {
		for k in inner do delete(k, w.allocator)
		delete(inner)
	}
	clear(&w.native.prev)
	kqueue_rec_add_watch(w, w.path)
	return .None
}

kqueue_rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {

	cs, cs_err := strings.clone_to_cstring(dir, context.temp_allocator)
	if cs_err != nil do return

	fd := posix.open(cs, posix.O_Flags{})
	if fd == posix.FD(-1) do return
	track_open(w, fd)

	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno2 := kqueue.kevent(w.native.kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE {
		posix.close(fd)
		track_close(w, fd)
		return
	}

	w.native.watches[int(fd)] = strings.clone(dir, w.allocator)

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
			kqueue_rec_add_watch(w, subdir)
		}
	}
}

backend_rec_get_events :: proc(w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	kqueue_drain_rec(w, allocator, out)
}

// === Shared kqueue read helpers ===

@(private)
kqueue_drain_file :: proc(w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	events: [1]kqueue.KEvent
	for {
		n, _ := kqueue.kevent(w.native.kq, nil, events[:], &no_wait)
		if n <= 0 do break
		ev := events[0]
		if ev.filter == .VNode {
			fflags := ev.fflags.vnode
			if fflags != {} {
				kind := kq_normalize(fflags)
				append(out, Event{kind = kind, path = strings.clone(w.path, allocator)})
			}
		}
	}
}

@(private)
kqueue_drain_dir :: proc(w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	events: [1]kqueue.KEvent
	_, _ = kqueue.kevent(w.native.kq, nil, events[:], &no_wait)

	old := w.native.prev
	current := make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name_alloc(w.path, &current, w.allocator)

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

	for k in old { delete(k, w.allocator) }
	delete(old)
	w.native.prev = current
}

@(private)
kqueue_drain_rec :: proc(w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	events: [64]kqueue.KEvent
	_, _ = kqueue.kevent(w.native.kq, nil, events[:], &no_wait)

	for dir_path, dir_prev in w.native.prev {
		current := make(map[string]File_Info, w.allocator)
		snapshot_dir_by_name_alloc(dir_path, &current, w.allocator)

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
				if fi.is_dir {
					kqueue_rec_add_watch(w, fullpath)
				}
				append(out, Event{kind = .Added, path = fullpath, is_dir = fi.is_dir})
			} else if fi.mtime != prev_fi.mtime || fi.size != prev_fi.size {
				fullpath, join_err := filepath.join({dir_path, name}, allocator)
				if join_err != nil { continue }
				append(out, Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir})
			}
		}

		for k in dir_prev { delete(k, w.allocator) }
		delete(dir_prev)
		w.native.prev[dir_path] = current
	}
}
