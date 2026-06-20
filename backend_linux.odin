// backend_linux.odin — Linux inotify backend.
//
// Non-blocking read of the inotify fd. Each get_events call reads all
// available events from the kernel buffer into a fresh slice. No
// accumulation between calls.
//
//   - Watcher_File:      single inotify watch on the file's parent dir
//   - Watcher_Dir:       single inotify watch on the directory
//   - Watcher_Recursive: one inotify fd + one watch per subdirectory

#+private package
package fsw

import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:path/filepath"

INOTIFY_BUF_SIZE :: 4096
INOTIFY_MASK     :: linux.Inotify_Event_Mask{
	.MODIFY, .CREATE, .DELETE, .DELETE_SELF,
	.MOVE_SELF, .ATTRIB, .CLOSE_WRITE,
} | linux.IN_MOVE

// === Platform-specific native data ===

Native_File :: struct {
	fd: linux.Fd,
	wd: linux.Wd,
}

Native_Dir :: struct {
	fd: linux.Fd,
	wd: linux.Wd,
}

Native_Recursive :: struct {
	fd:      linux.Fd,
	watches: map[linux.Wd]string,
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> (err: Error) {

	track_start(w)

	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, fd)
	defer if err != nil {
		linux.close(fd)
		track_close(w, fd)
	}

	cs, _ := strings.clone_to_cstring(w.path, context.temp_allocator)
	wd, errno2 := linux.inotify_add_watch(fd, cs, INOTIFY_MASK)
	if errno2 != .NONE do return .Backend_Init_Failed

	w.native.fd = fd
	w.native.wd = wd

	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	linux.close(w.native.fd)
	track_close(w, w.native.fd)
	track_end(w)
}

backend_file_get_events :: proc(w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	inotify_read(w.native.fd, w.native.wd, w.path, out, allocator)
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> (err: Error) {

	track_start(w)

	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, fd)
	defer if err != nil {
		linux.close(fd)
		track_close(w, fd)
	}

	cs, _ := strings.clone_to_cstring(w.path, context.temp_allocator)
	wd, errno2 := linux.inotify_add_watch(fd, cs, INOTIFY_MASK)
	if errno2 != .NONE do return .Backend_Init_Failed

	w.native.fd = fd
	w.native.wd = wd

	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	linux.close(w.native.fd)
	track_close(w, w.native.fd)
	track_end(w)
}

backend_dir_get_events :: proc(w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	inotify_read(w.native.fd, w.native.wd, w.path, out, allocator)
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {

	track_start(w)

	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, fd)

	w.native.fd = fd
	w.native.watches = make(map[linux.Wd]string, w.allocator)

	rec_add_watch(w, w.path)

	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	for wd_key in w.native.watches {
		linux.inotify_rm_watch(w.native.fd, linux.Wd(wd_key))
	}
	linux.close(w.native.fd)
	track_close(w, w.native.fd)
	track_end(w)
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

	cs, _ := strings.clone_to_cstring(dir, context.temp_allocator)
	wd, errno := linux.inotify_add_watch(w.native.fd, cs, INOTIFY_MASK)
	if errno != .NONE do return

	w.native.watches[wd] = strings.clone(dir, w.allocator)

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

backend_rec_get_events :: proc(w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	inotify_read_rec(w, allocator, out)
}

// === Shared read helper ===

// inotify_read repeatedly reads the inotify fd until EAGAIN, appending all
// events matching `target_wd` to `out`. Events not matching are consumed
// from the kernel buffer and discarded.
inotify_read :: proc(
	fd: linux.Fd,
	target_wd: linux.Wd,
	parent_path: string,
	out: ^[dynamic]Event,
	allocator: mem.Allocator,
) {
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

			ev: Event
			ev.is_dir = .ISDIR in event.mask
			ev.kind = inotify_normalize(event.mask)
			if name := inotify_event_name(event); name != "" {
				ev.path, _ = filepath.join({parent_path, name}, allocator)
			} else {
				ev.path = strings.clone(parent_path, allocator)
			}

			append(out, ev)
		}
	}
}

// inotify_read_rec reads from a recursive watcher's inotify fd, appending
// all events to `out`. New subdirectories are auto-watched on .Added
// events.
inotify_read_rec :: proc(w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
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

			ev: Event
			ev.kind = inotify_normalize(event.mask)

			dir_path := w.native.watches[event.wd] or_continue
			if name := inotify_event_name(event); name != "" {
				ev.path, _ = filepath.join({dir_path, name}, allocator)
			} else {
				ev.path = strings.clone(dir_path, allocator)
			}

			// Auto-watch new subdirs BEFORE emitting event to avoid race
			ev.is_dir = .ISDIR in event.mask
			if ev.kind == .Added && ev.is_dir {
				rec_add_watch(w, ev.path)
			}

			// Coalesce consecutive .Modified events for the same path.
			if ev.kind == .Modified && len(out) > 0 {
				last := &out[len(out)-1]
				if last.kind == .Modified && last.path == ev.path {
					delete(ev.path, allocator)
					continue
				}
			}

			append(out, ev)
		}
	}
}

// === Event helpers ===

@require_results
inotify_normalize :: proc(mask: linux.Inotify_Event_Mask) -> Event_Kind {
	if .DELETE in mask || .DELETE_SELF in mask || .MOVED_FROM in mask {
		return .Removed
	}
	if .CREATE in mask || .MOVED_TO in mask {
		return .Added
	}
	if .MOVE_SELF in mask {
		return .Renamed
	}
	return .Modified
}

@require_results
inotify_event_name :: proc(event: ^linux.Inotify_Event) -> string {
	if event.len == 0 do return ""
	return string(cstring(cast([^]u8)&event.name))
}
