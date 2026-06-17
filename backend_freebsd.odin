// backend_freebsd.odin — FreeBSD backend using kqueue + EVFILT_VNODE.
//
// Platform-specific backend compiled only on FreeBSD.
// Identical architecture to backend_darwin.odin — see that file for details.
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.

package fsw

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

	w.native_handle = int(kq)
	t := thread.create(freebsd_file_thread)
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
		file := (^os.File)(w.thread.user_args[1])
		os.close(file)
		thread.destroy(w.thread)
	}
	posix.close(kq)
}

freebsd_file_thread :: proc(t: ^thread.Thread) {
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

	w.native_handle = int(kq)
	t := thread.create(freebsd_dir_thread)
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

freebsd_dir_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Dir)(t.data)
	kq := posix.FD(w.native_handle)

	// Take initial snapshot
	w.prev = make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name(w.path, &w.prev)

	events: [1]kqueue.KEvent
	for w.running {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000}
		_, _ = kqueue.kevent(kq, nil, events[:], &timeout)

		// Always poll — kqueue VNode doesn't catch file content changes
		current := make(map[string]File_Info, w.allocator)
		snapshot_dir_by_name(w.path, &current)

		for name in w.prev {
			if _, ok := current[name]; !ok {
				e := Event{kind = .Removed, path = name}
				invoke_callback_dir(w, &e)
			}
		}

		for name, fi in current {
			prev, ok := w.prev[name]
			if !ok {
				e := Event{kind = .Added, path = name, is_dir = fi.is_dir}
				invoke_callback_dir(w, &e)
			} else if fi.mtime != prev.mtime || fi.size != prev.size {
				e := Event{kind = .Modified, path = name, is_dir = fi.is_dir}
				invoke_callback_dir(w, &e)
			}
		}

		delete(w.prev)
		w.prev = current
	}
	delete(w.prev)
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	kq, errno := kqueue.kqueue()
	if errno != .NONE { return .Backend_Init_Failed }
	w.native_handle = int(kq)
	w.watches = make(map[int]string, w.allocator)
	w.prev = make(map[string]map[string]File_Info, w.allocator)

	freebsd_rec_add_watch(w, w.path)

	t := thread.create(freebsd_rec_thread)
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
	// Clear prev snapshots
	for _, inner in w.prev {
		delete(inner)
	}
	clear(&w.prev)
	freebsd_rec_add_watch(w, w.path)
	return .None
}

freebsd_rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	file, err := os.open(dir, os.O_RDONLY)
	if err != nil { return }
	fd := int(os.fd(file))

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

	// Take initial snapshot of this dir
	dir_prev := make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name(dir, &dir_prev)
	w.prev[dir] = dir_prev

	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		if entry.type == .Directory {
			subdir := filepath.join({dir, entry.name}, context.temp_allocator) or_continue
            freebsd_rec_add_watch(w, subdir)
		}
	}
}

freebsd_rec_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Recursive)(t.data)
	kq := posix.FD(w.native_handle)
	gw := (^Watcher_Glob)(w.user_data)

	events: [64]kqueue.KEvent
	for w.running {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000}
		_, _ = kqueue.kevent(kq, nil, events[:], &timeout)

		// Poll all watched dirs — kqueue VNode doesn't catch file content changes
		for fd_key, dir_path in w.watches {
			_ = fd_key
			current := make(map[string]File_Info, w.allocator)
			snapshot_dir_by_name(dir_path, &current)

			dir_prev, has_prev := w.prev[dir_path]
			if has_prev {
				for name in dir_prev {
					if _, ok := current[name]; !ok {
						fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
						if join_err != nil { continue }
						e := Event{kind = .Removed, path = fullpath}
						if gw != nil {
							glob_filter_event(gw, &e)
						} else {
							invoke_callback_rec(w, &e)
						}
					}
				}

				for name, fi in current {
					prev_fi, ok := dir_prev[name]
					if !ok {
						fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
						if join_err != nil { continue }
						// Auto-watch new subdirs BEFORE emitting event to avoid race
						if fi.is_dir {
							freebsd_rec_add_watch(w, fullpath)
						}
						e := Event{kind = .Added, path = fullpath, is_dir = fi.is_dir}
						if gw != nil {
							glob_filter_event(gw, &e)
						} else {
							invoke_callback_rec(w, &e)
						}
					} else if fi.mtime != prev_fi.mtime || fi.size != prev_fi.size {
						fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
						if join_err != nil { continue }
						e := Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir}
						if gw != nil {
							glob_filter_event(gw, &e)
						} else {
							invoke_callback_rec(w, &e)
						}
					}
				}

				delete(dir_prev)
			}

			w.prev[dir_path] = current
		}
	}
	// Cleanup prev maps
	for _, inner in w.prev {
		delete(inner)
	}
	delete(w.prev)
}
