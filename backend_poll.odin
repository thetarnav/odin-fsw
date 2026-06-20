// backend_poll.odin — Polling backend for all platforms.
//
// Pull-based stat polling. No threads are started. Each get_events call
// performs a single poll cycle (one stat or one snapshot diff) and appends
// all events to the caller's dynamic array. The user is responsible for
// sleeping between calls.
//
//   - Watcher_File_Poll: polls a single file with file_stat()
//   - Watcher_Dir_Poll: snapshot-diffs a directory each call
//   - Watcher_Recursive_Poll: snapshot-diffs recursively each call
//
// File deletion is tracked via a prev.size < 0 sentinel. When a file disappears,
// a .Removed event fires; when it reappears, .Added fires.
//
// Event paths are allocated with the allocator passed to get_events.
// Watcher state (prev map, snapshot maps) is allocated with the watcher's
// allocator.

package fsw

import "core:mem"
import "core:os"
import "core:strings"

poll_file_get_events :: proc(w: ^Watcher_File_Poll, allocator: mem.Allocator, out: ^[dynamic]Event) {
	os_fi, err := file_stat_alloc(w.path, w.allocator)
	if err != .None {
		os.file_info_delete(os_fi, w.allocator)
		if w.prev.size >= 0 {
			w.prev = File_Info{size = -1}
			append(out, Event{kind = .Removed, path = strings.clone(w.path, allocator)})
		}
		return
	}
	defer os.file_info_delete(os_fi, w.allocator)
	fi := File_Info{
		is_dir = os_fi.type == .Directory,
		size   = os_fi.size,
		mtime  = os_fi.modification_time,
		inode  = os_fi.inode,
	}
	if w.prev.size < 0 {
		w.prev = fi
		append(out, Event{kind = .Added, path = strings.clone(w.path, allocator)})
		return
	}
	changed := fi.mtime != w.prev.mtime || fi.size != w.prev.size || fi.inode != w.prev.inode
	if changed {
		kind := Event_Kind.Modified
		if fi.inode != w.prev.inode {
			kind = .Renamed
		}
		w.prev = fi
		append(out, Event{kind = kind, path = strings.clone(w.path, allocator)})
	}
}

poll_dir_get_events :: proc(w: ^Watcher_Dir_Poll, allocator: mem.Allocator, out: ^[dynamic]Event) {
	old := w.prev
	current := make(map[string]File_Info, w.allocator)
	snapshot_dir_alloc(w.path, &current, w.allocator, fullpath=true, recursive=false)

	for path in old {
		if _, ok := current[path]; !ok {
			append(out, Event{kind = .Removed, path = strings.clone(path, allocator)})
		}
	}

	for path, fi in current {
		prev, ok := old[path]
		if !ok {
			append(out, Event{kind = .Added, path = strings.clone(path, allocator), is_dir = fi.is_dir})
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			append(out, Event{kind = .Modified, path = strings.clone(path, allocator), is_dir = fi.is_dir})
		}
	}

	for path in old {
		delete(path, w.allocator)
	}
	delete(old)
	w.prev = current
}

poll_rec_get_events :: proc(w: ^Watcher_Recursive_Poll, allocator: mem.Allocator, out: ^[dynamic]Event) {
	old := w.prev
	current := make(map[string]File_Info, w.allocator)
	snapshot_dir_alloc(w.path, &current, w.allocator, fullpath=true, recursive=true)

	for path in old {
		if _, in_current := current[path]; !in_current {
			append(out, Event{kind = .Removed, path = strings.clone(path, allocator)})
		}
	}

	for path, fi in current {
		prev, in_old := old[path]
		if !in_old {
			append(out, Event{kind = .Added, path = strings.clone(path, allocator), is_dir = fi.is_dir})
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			append(out, Event{kind = .Modified, path = strings.clone(path, allocator), is_dir = fi.is_dir})
		}
	}

	for path in old {
		delete(path, w.allocator)
	}
	delete(old)
	w.prev = current
}
