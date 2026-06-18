// backend_linux.odin — Linux backend using inotify + shared epoll event loop.
//
// Platform-specific backend compiled only on Linux.
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.
//
// Architecture:
//   - Each watcher creates an inotify fd with inotify_init1({.NONBLOCK, .CLOEXEC})
//   - The fd is registered with the shared epoll event loop (event_loop_linux.odin)
//   - The shared loop thread reads inotify events and dispatches to the watcher
//   - Events are normalized via inotify_normalize() into Event_Kind values
//   - Recursive watcher: per-subdirectory inotify watches stored in w.watches map
//     (wd → dir_path). New subdirs are auto-watched on .Added events.
//   - Glob routing: the dispatch proc checks w.user_data; if non-nil, events
//     go through glob_filter_event instead of the direct callback.
//
// Internal helpers: to_cstring, inotify_normalize, inotify_event_name, rec_add_watch

package fsw

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

INOTIFY_MASK :: linux.Inotify_Event_Mask{
	.CREATE, .MODIFY, .DELETE, .MOVED_FROM, .MOVED_TO,
	.DELETE_SELF, .MOVE_SELF, .CLOSE_WRITE, .ISDIR,
}

to_cstring :: proc(s: string, allocator := context.temp_allocator) -> cstring {
	buf := make([]byte, len(s) + 1, allocator)
	copy(buf, s)
	buf[len(s)] = 0
	return cstring(&buf[0])
}

inotify_normalize :: proc(mask: linux.Inotify_Event_Mask) -> Event_Kind {
	if .Q_OVERFLOW in mask { return .Overflow }
	if .UNMOUNT in mask || .IGNORED in mask { return .Invalidated }
	if .MOVED_FROM in mask { return .Renamed }
	if .MOVED_TO in mask { return .Renamed }
	if .CREATE in mask { return .Added }
	if .DELETE in mask || .DELETE_SELF in mask { return .Removed }
	if .MODIFY in mask || .CLOSE_WRITE in mask || .ATTRIB in mask { return .Modified }
	return .Modified
}

inotify_event_name :: proc(event: ^linux.Inotify_Event, allocator := context.temp_allocator) -> string {
	if event.len == 0 { return "" }
	name_ptr := rawptr(uintptr(&event^) + size_of(linux.Inotify_Event))
	return strings.clone_from_cstring(cstring(name_ptr), allocator)
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return .Backend_Init_Failed
	}
	cs := to_cstring(w.path)
	wd, errno2 := linux.inotify_add_watch(fd, cs, INOTIFY_MASK)
	if errno2 != .NONE {
		linux.close(fd)
		return .Backend_Init_Failed
	}
	w.native_handle = int(fd)
	w.wd = int(wd)
	loop := get_loop()
	if loop == nil {
		linux.close(fd)
		return .Backend_Init_Failed
	}
	loop_add_watcher(loop, fd, Loop_Watcher(w))
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, linux.Fd(w.native_handle))
	}
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return .Backend_Init_Failed
	}
	cs := to_cstring(w.path)
	wd, errno2 := linux.inotify_add_watch(fd, cs, INOTIFY_MASK)
	if errno2 != .NONE {
		linux.close(fd)
		return .Backend_Init_Failed
	}
	w.native_handle = int(fd)
	w.wd = int(wd)
	loop := get_loop()
	if loop == nil {
		linux.close(fd)
		return .Backend_Init_Failed
	}
	loop_add_watcher(loop, fd, Loop_Watcher(w))
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, linux.Fd(w.native_handle))
	}
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return .Backend_Init_Failed
	}
	w.native_handle = int(fd)
	w.watches = make(map[int]string, w.allocator)
	rec_add_watch(w, w.path)
	loop := get_loop()
	if loop == nil {
		linux.close(fd)
		return .Backend_Init_Failed
	}
	loop_add_watcher(loop, fd, Loop_Watcher(w))
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, linux.Fd(w.native_handle))
	}
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	fd := linux.Fd(w.native_handle)
	for wd_key in w.watches {
		linux.inotify_rm_watch(fd, linux.Wd(wd_key))
	}
	clear(&w.watches)
	rec_add_watch(w, w.path)
	return .None
}

rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	cs := to_cstring(dir)
	wd, errno := linux.inotify_add_watch(linux.Fd(w.native_handle), cs, INOTIFY_MASK)
	if errno != .NONE do return

	w.watches[int(wd)] = strings.clone(dir, w.allocator)

	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		if entry.type == .Directory {
			subdir := filepath.join({dir, entry.name}, context.temp_allocator) or_continue
			rec_add_watch(w, subdir)
		}
	}
}
