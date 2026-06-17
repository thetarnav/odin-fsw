package fsw

// macOS backend — kqueue + EVFILT_VNODE for all watcher types.
// Recursive watching registers each subdirectory individually.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"
import "core:thread"

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

	fd := int((^os.File_Impl)(file.impl).fd)
	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	n, errno2 := kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
	if errno2 != .NONE {
		posix.close(kq)
		os.close(file)
		return .Backend_Init_Failed
	}

	w.native_handle = int(kq)
	t := thread.create(darwin_file_thread)
	t.data = rawptr(w)
	t.user_args[0] = rawptr(uintptr(fd))
	t.user_args[1] = rawptr(file)
	thread.start(t)
	w.thread = t
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	kq := posix.FD(w.native_handle)
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		fd := int(uintptr(w.thread.user_args[0]))
		file := (^os.File)(w.thread.user_args[1])
		os.close(file)
		_ = fd
		thread.destroy(w.thread)
	}
	posix.close(kq)
}

darwin_file_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_File)(t.data)
	kq := posix.FD(w.native_handle)

	events: [1]kqueue.KEvent
	for w.running {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000} // 100ms
		n, _ := kqueue.kevent(kq, nil, events[:], &timeout)
		if n <= 0 { continue }

		if events[0].filter == .VNode {
			fflags := events[0].fflags.vnode
			if fflags == {} { continue }
			kind := kq_normalize(fflags)
			e := Event{kind = kind, path = w.path}
			invoke_callback_file(w, &e)
		}
	}
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

	fd := int((^os.File_Impl)(file.impl).fd)
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

	w.native_handle = int(kq)
	t := thread.create(darwin_dir_thread)
	t.data = rawptr(w)
	t.user_args[0] = rawptr(uintptr(fd))
	t.user_args[1] = rawptr(file)
	thread.start(t)
	w.thread = t
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	kq := posix.FD(w.native_handle)
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		file := (^os.File)(w.thread.user_args[1])
		os.close(file)
		thread.destroy(w.thread)
	}
	posix.close(kq)
}

darwin_dir_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Dir)(t.data)
	kq := posix.FD(w.native_handle)

	events: [1]kqueue.KEvent
	for w.running {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000}
		n, _ := kqueue.kevent(kq, nil, events[:], &timeout)
		if n <= 0 { continue }

		if events[0].filter == .VNode {
			fflags := events[0].fflags.vnode
			if fflags == {} { continue }
			kind := kq_normalize(fflags)
			e := Event{kind = kind, path = w.path, is_dir = true}
			invoke_callback_dir(w, &e)
		}
	}
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	kq, errno := kqueue.kqueue()
	if errno != .NONE { return .Backend_Init_Failed }
	w.native_handle = int(kq)
	w.watches = make(map[int]string, w.allocator)

	darwin_rec_add_watch(w, w.path)

	t := thread.create(darwin_rec_thread)
	t.data = rawptr(w)
	thread.start(t)
	w.thread = t
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	kq := posix.FD(w.native_handle)
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	for fd_key in w.watches {
		posix.close(posix.FD(fd_key))
	}
	posix.close(kq)
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	kq := posix.FD(w.native_handle)
	for fd_key in w.watches {
		posix.close(posix.FD(fd_key))
	}
	clear(&w.watches)
	darwin_rec_add_watch(w, w.path)
	return .None
}

darwin_rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	file, err := os.open(dir, os.O_RDONLY)
	if err != nil do return
	fd := (^os.File_Impl)(file.impl).fd

	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	_, errno := kqueue.kevent(posix.FD(w.native_handle), []kqueue.KEvent{ev}, nil, nil)
	if errno != .NONE {
		os.close(file)
		return
	}

	w.watches[fd] = strings.clone(dir, w.allocator)

	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		if entry.type == .Directory {
			subdir := filepath.join({dir, entry.name}, context.temp_allocator) or_continue
            darwin_rec_add_watch(w, subdir)
		}
	}
}

darwin_rec_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Recursive)(t.data)
	kq := posix.FD(w.native_handle)
	gw := (^Watcher_Glob)(w.user_data)

	events: [64]kqueue.KEvent
	for w.running {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000}
		n, _ := kqueue.kevent(kq, nil, events[:], &timeout)
		if n <= 0 do continue

		for i in 0..<n {
			if events[i].filter != .VNode do continue
			fflags := events[i].fflags.vnode
			if fflags == {} do continue

			fd := int(events[i].ident)
			dir_path, ok := w.watches[fd]
			if !ok do continue

			kind := kq_normalize(fflags)
			e := Event{kind = kind, path = dir_path, is_dir = true}

			if gw != nil {
				glob_filter_event(gw, &e)
			} else {
				invoke_callback_rec(w, &e)
			}

			if kind == .Added {
				darwin_rec_add_watch(w, dir_path)
			}
		}
	}
}
