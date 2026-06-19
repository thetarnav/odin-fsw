// backend_linux.odin — Linux backend using inotify.
//
// Platform-specific backend compiled only on Linux.
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.
//
// Pull-based architecture:
//   - Each watcher creates an inotify fd with inotify_init1({.NONBLOCK, .CLOEXEC})
//   - backend_*_get_event(s) procs do a non-blocking read from the fd
//   - Events are normalized via inotify_normalize() into Event_Kind values
//   - Recursive watcher: per-subdirectory inotify watches stored in w.native.watches
//     (wd → dir_path). New subdirs are auto-watched on .Added events during read.
//
// Internal helpers: to_cstring, inotify_normalize, inotify_event_name, rec_add_watch

package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

// === Platform-specific native data ===
// The Native_* structs hold the inotify fd/watch-descriptor pair.

Native_File :: struct {
	fd: linux.Fd, // inotify fd
	wd: linux.Wd, // watch descriptor for the target file
}

Native_Dir :: struct {
	fd: linux.Fd, // inotify fd
	wd: linux.Wd, // watch descriptor for the target directory
}

Native_Recursive :: struct {
	fd:      linux.Fd,        // inotify fd
	watches: map[int]string,  // wd -> dir_path
}

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

@(private)
INOTIFY_BUF_SIZE :: 8192

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
	w.native.fd = fd
	w.native.wd = wd
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	linux.close(w.native.fd)
}

backend_file_get_event :: proc(w: ^Watcher_File) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return inotify_read(w.native.fd, w.native.wd, w.path, &w.events, w.allocator, drain=false)
}

backend_file_get_events :: proc(w: ^Watcher_File) -> []Event {
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)
	inotify_read(w.native.fd, w.native.wd, w.path, &w.events, w.allocator, drain=true)
	if len(w.events) == 0 do return nil
	return w.events[:]
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
	w.native.fd = fd
	w.native.wd = wd
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	linux.close(w.native.fd)
}

backend_dir_get_event :: proc(w: ^Watcher_Dir) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return inotify_read(w.native.fd, w.native.wd, w.path, &w.events, w.allocator, drain=false)
}

backend_dir_get_events :: proc(w: ^Watcher_Dir) -> []Event {
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)
	inotify_read(w.native.fd, w.native.wd, w.path, &w.events, w.allocator, drain=true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return .Backend_Init_Failed
	}
	w.native.fd = fd
	w.native.watches = make(map[int]string, w.allocator)
	rec_add_watch(w, w.path)
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	for wd_key in w.native.watches {
		linux.inotify_rm_watch(w.native.fd, linux.Wd(wd_key))
	}
	linux.close(w.native.fd)
}

backend_rec_native_cleanup :: proc(w: ^Watcher_Recursive) {
	for _, v in w.native.watches {
		delete(v, w.allocator)
	}
	delete(w.native.watches)
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	for wd_key in w.native.watches {
		linux.inotify_rm_watch(w.native.fd, linux.Wd(wd_key))
	}
	for _, v in w.native.watches {
		delete(v, w.allocator)
	}
	clear(&w.native.watches)
	rec_add_watch(w, w.path)
	return .None
}

rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	cs := to_cstring(dir)
	wd, errno := linux.inotify_add_watch(w.native.fd, cs, INOTIFY_MASK)
	if errno != .NONE do return

	w.native.watches[int(wd)] = strings.clone(dir, w.allocator)

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

backend_rec_get_event :: proc(w: ^Watcher_Recursive) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return inotify_read_rec(w, drain=false)
}

backend_rec_get_events :: proc(w: ^Watcher_Recursive) -> []Event {
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)
	inotify_read_rec(w, drain=true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Shared read helper ===

// inotify_read does one non-blocking read from fd. Events matching `target_wd` are
// appended to `out`. If `drain` is true, repeatedly reads until EAGAIN. For file/dir
// watchers, `target_wd` filters to the single watch descriptor.
@(private)
inotify_read :: proc(
	fd: linux.Fd,
	target_wd: linux.Wd,
	parent_path: string,
	out: ^[dynamic]Event,
	allocator: mem.Allocator,
	drain: bool,
) -> (e: Event, got_one: bool) {
	buf: [INOTIFY_BUF_SIZE]byte
	for {
		n, errno := linux.read(fd, buf[:])
		if errno == .EAGAIN || n <= 0 {
			break
		}
		offset := 0
		for offset < n {
			event := (^linux.Inotify_Event)(&buf[offset])
			defer offset += size_of(linux.Inotify_Event) + int(event.len)

			if event.wd != target_wd do continue

			e.is_dir = .ISDIR in event.mask
			e.kind = inotify_normalize(event.mask)
			if name := inotify_event_name(event); name != "" {
				e.path, _ = filepath.join({parent_path, name}, allocator)
			} else {
				e.path = strings.clone(parent_path, allocator)
			}

			got_one = true
			if drain {
				append(out, e)
			} else {
				return
			}
		}
		if !drain do break
	}
	return
}

// inotify_read_rec reads from a recursive watcher's inotify fd. Handles multiple
// watch descriptors. New subdirectories are auto-watched on .Added events.
@(private)
inotify_read_rec :: proc (w: ^Watcher_Recursive, drain: bool) -> (e: Event, got_one: bool) {
	buf: [INOTIFY_BUF_SIZE]byte
	for {
		n, errno := linux.read(w.native.fd, buf[:])
		if errno == .EAGAIN || n <= 0 {
			break
		}
		offset := 0
		for offset < n {
			event := (^linux.Inotify_Event)(&buf[offset])
			defer offset += size_of(linux.Inotify_Event) + int(event.len)

			e.kind = inotify_normalize(event.mask)

			dir_path := w.native.watches[int(event.wd)] or_continue
			if name := inotify_event_name(event); name != "" {
				e.path, _ = filepath.join({dir_path, name}, w.allocator)
			} else {
				e.path = strings.clone(dir_path, w.allocator)
			}

			// Auto-watch new subdirs BEFORE emitting event to avoid race
			e.is_dir = .ISDIR in event.mask
			if e.kind == .Added && e.is_dir {
				rec_add_watch(w, e.path)
			}

			got_one = true
			if drain {
				append(&w.events, e)
			} else {
				return
			}
		}
		if !drain do break
	}
	return
}
