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
	fd:       linux.Fd,
	wd:       linux.Wd,     // current watch descriptor (file or parent dir)
	dir_mode: bool,           // true = wd watches parent dir, waiting for file to reappear
	parent:   string,         // absolute path of parent directory
	target:   string,         // filename being watched
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

backend_file_init :: proc (w: ^Watcher_File) -> (err: Error) {

	track_start(w)

	parent, target := filepath.split(w.path)
	if parent == "" do parent = "."

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

	w.fd       = fd
	w.wd       = wd
	w.dir_mode = false

	parent_clone, perr := strings.clone(parent, w.allocator)
	if perr != nil do return .Backend_Init_Failed
	w.parent = parent_clone

	target_clone, terr := strings.clone(target, w.allocator)
	if terr != nil {
		delete(w.parent, w.allocator)
		return .Backend_Init_Failed
	}
	w.target = target_clone

	return .None
}

backend_file_destroy :: proc (w: Watcher_File) {
	local := w
	if local.fd >= 0 && local.wd >= 0 {
		linux.inotify_rm_watch(local.fd, local.wd)
	}
	if local.fd >= 0 {
		linux.close(local.fd)
		track_close(&local, local.fd)
	}
	if local.parent != "" {
		delete(local.parent, local.allocator)
	}
	if local.target != "" {
		delete(local.target, local.allocator)
	}
	track_end(&local)
}

backend_file_get_events :: proc (w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	file_inotify_read(w, allocator, out)
}

// === Watcher_Dir ===

backend_dir_init :: proc (w: ^Watcher_Dir) -> (err: Error) {

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

	w.fd = fd
	w.wd = wd

	return .None
}

backend_dir_destroy :: proc (w: Watcher_Dir) {
	linux.close(w.fd)
	track_close(w, w.fd)
	track_end(w)
}

backend_dir_get_events :: proc (w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	inotify_read(w.fd, w.wd, w.path, out, allocator)
}

// === Watcher_Recursive ===

backend_rec_init :: proc (w: ^Watcher_Recursive) -> Error {

	track_start(w)

	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE do return .Backend_Init_Failed
	track_open(w, fd)

	w.fd = fd
	w.watches = make(map[linux.Wd]string, w.allocator)

	rec_add_watch(w, w.path)

	return .None
}

backend_rec_destroy :: proc (w: Watcher_Recursive) {
	for wd_key, v in w.watches {
		linux.inotify_rm_watch(w.fd, linux.Wd(wd_key))
		delete(v, w.allocator)
	}
	delete(w.watches)
	linux.close(w.fd)
	track_close(w, w.fd)
	track_end(w)
}

backend_rec_rescan :: proc (w: ^Watcher_Recursive) -> Error {
	for wd_key in w.watches {
		linux.inotify_rm_watch(w.fd, linux.Wd(wd_key))
	}
	for _, v in w.watches {
		delete(v, w.allocator)
	}
	clear(&w.watches)
	rec_add_watch(w, w.path)
	return .None
}

rec_add_watch :: proc (w: ^Watcher_Recursive, dir: string) {

	cs, _ := strings.clone_to_cstring(dir, context.temp_allocator)
	wd, errno := linux.inotify_add_watch(w.fd, cs, INOTIFY_MASK)
	if errno != .NONE do return

	w.watches[wd] = strings.clone(dir, w.allocator)

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

backend_rec_get_events :: proc (w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	inotify_read_rec(w, allocator, out)
}

// === Shared read helper ===

// inotify_read repeatedly reads the inotify fd until EAGAIN, appending events
// to `out`. In file mode it filters by `w.wd`; in dir mode it filters by
// filename and watches for the file to reappear. State transitions:
//
//   file mode  --(IN_DELETE_SELF | IN_MOVE_SELF)-->  dir mode
//   dir  mode  --(IN_CREATE | IN_MOVED_TO on target)--> file mode
file_inotify_read :: proc (w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	buf: [INOTIFY_BUF_SIZE]byte
	for {
		n, errno := linux.read(w.fd, buf[:])
		if errno == .EAGAIN || n <= 0 {
			break
		}
		offset := 0
		for offset < n {
			event := (^linux.Inotify_Event)(&buf[offset])
			defer offset += size_of(linux.Inotify_Event) + int(event.len)

			ev: Event
			ev.is_dir = .ISDIR in event.mask

			if w.dir_mode {
				// Watching parent dir, filter by filename
				name := inotify_event_name(event)
				if name != w.target do continue
				if .IGNORED in event.mask do continue

				if .CREATE in event.mask || .MOVED_TO in event.mask {
					// File reappeared — switch back to file watch
					linux.inotify_rm_watch(w.fd, w.wd)
					cs, _ := strings.clone_to_cstring(w.path, context.temp_allocator)
					new_wd, errno2 := linux.inotify_add_watch(w.fd, cs, INOTIFY_MASK)
					if errno2 == .NONE {
						w.wd       = new_wd
						w.dir_mode = false
					}
					ev.kind = .Added
					ev.path = strings.clone(w.path, allocator)
					append(out, ev)
				}
				// Other events for the target filename in dir mode are ignored.
			} else {
				// Watching file directly
				if event.wd != w.wd do continue
				if .IGNORED in event.mask do continue

				if .DELETE_SELF in event.mask || .MOVE_SELF in event.mask {
					// File deleted/moved — switch to parent dir watch
					linux.inotify_rm_watch(w.fd, w.wd)
					cs, _ := strings.clone_to_cstring(w.parent, context.temp_allocator)
					new_wd, errno2 := linux.inotify_add_watch(w.fd, cs, INOTIFY_MASK)
					if errno2 == .NONE {
						w.wd       = new_wd
						w.dir_mode = true
					}
					ev.kind = .Removed
					ev.path = strings.clone(w.path, allocator)
				} else {
					ev.kind = inotify_normalize(event.mask)
					ev.path = strings.clone(w.path, allocator)
				}

				// Coalesce consecutive .Modified events for the same path
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
}

// inotify_read repeatedly reads the inotify fd until EAGAIN, appending all
// events matching `target_wd` to `out`. Events not matching are consumed
// from the kernel buffer and discarded.
inotify_read :: proc (
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
inotify_read_rec :: proc (w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	buf: [INOTIFY_BUF_SIZE]byte
	for {
		n, errno := linux.read(w.fd, buf[:])
		if errno == .EAGAIN || n <= 0 {
			break
		}
		offset := 0
		for offset < n {
			event := (^linux.Inotify_Event)(&buf[offset])
			defer offset += size_of(linux.Inotify_Event) + int(event.len)

			ev: Event
			ev.kind = inotify_normalize(event.mask)

			dir_path := w.watches[event.wd] or_continue
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
inotify_normalize :: proc (mask: linux.Inotify_Event_Mask) -> Event_Kind {
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
inotify_event_name :: proc (event: ^linux.Inotify_Event) -> string {
	if event.len == 0 do return ""
	return string(cstring(cast([^]u8)&event.name))
}
