// backend_darwin.odin — macOS backend using kqueue + EVFILT_VNODE.
//
// Platform-specific backend compiled only on macOS.
// Uses a shared kqueue event loop (event_loop_darwin.odin).
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.

package fsw

import "core:os"
import "core:sys/kqueue"
import "core:sys/posix"

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

	fd := int(os.fd(file))
	w.native_handle = fd
	loop := get_loop()
	if loop == nil { os.close(file); return .Backend_Init_Failed }

	loop_add_watcher(loop, fd, Loop_Watcher(w))
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, w.native_handle)
	}
	posix.close(posix.FD(w.native_handle))
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	file, err := os.open(w.path, os.O_RDONLY)
	if err != nil { return .Backend_Init_Failed }

	fd := int(os.fd(file))
	w.native_handle = fd
	loop := get_loop()
	if loop == nil { os.close(file); return .Backend_Init_Failed }

	w.prev = make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name(w.path, &w.prev)

	loop_add_watcher(loop, fd, Loop_Watcher(w))
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, w.native_handle)
	}
	posix.close(posix.FD(w.native_handle))
	delete(w.prev)
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	loop := get_loop()
	if loop == nil { return .Backend_Init_Failed }

	w.watches = make(map[int]string, w.allocator)
	w.prev = make(map[string]map[string]File_Info, w.allocator)

	kq_rec_add_watch(w, w.path)

	loop_add_rec_watcher(loop, w)
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	loop := get_loop()
	if loop != nil {
		loop_remove_rec_watcher(loop, w)
	}
	for fd_key in w.watches {
		posix.close(posix.FD(fd_key))
	}
	for _, inner in w.prev {
		delete(inner)
	}
	delete(w.prev)
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	loop := get_loop()
	if loop == nil { return .Backend_Init_Failed }

	// Remove old kevents and close fds.
	loop_remove_rec_watcher(loop, w)
	for fd_key in w.watches {
		posix.close(posix.FD(fd_key))
	}
	clear(&w.watches)
	for _, inner in w.prev {
		delete(inner)
	}
	clear(&w.prev)

	// Re-add watches and register with loop.
	kq_rec_add_watch(w, w.path)
	loop_add_rec_watcher(loop, w)
	return .None
}
