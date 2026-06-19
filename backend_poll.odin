// backend_poll.odin — Polling backend for all platforms.
//
// Pull-based stat polling. No threads are started. Each get_event/get_events call
// performs a single poll cycle (one stat or one snapshot diff). The user is
// responsible for sleeping between calls.
//
//   - Watcher_File_Poll: polls a single file with file_stat()
//   - Watcher_Dir_Poll: snapshot-diffs a directory each call
//   - Watcher_Recursive_Poll: snapshot-diffs recursively each call
//
// File deletion is tracked via a prev.size < 0 sentinel. When a file disappears,
// a .Removed event fires; when it reappears, .Added fires.
//
// All event paths are clones allocated with the watcher's allocator. The events
// buffer is reused across calls; paths from the previous batch are freed before
// the next batch is generated. The user must clone paths if they want to keep
// them past the next get_event/get_events call.

package fsw

import "core:os"
import "core:strings"

// poll_file_get_event performs one stat() check and returns the next event.
// Returns false when no change is detected.
poll_file_get_event :: proc(w: ^Watcher_File_Poll) -> (Event, bool) {
	os_fi, err := file_stat_alloc(w.path, w.allocator)
	if err != .None {
		os.file_info_delete(os_fi, w.allocator)
		if w.prev.size >= 0 {
			w.prev = File_Info{size = -1}
			return Event{kind = .Removed, path = strings.clone(w.path, w.allocator)}, true
		}
		return {}, false
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
		return Event{kind = .Added, path = strings.clone(w.path, w.allocator)}, true
	}
	changed := fi.mtime != w.prev.mtime || fi.size != w.prev.size || fi.inode != w.prev.inode
	if changed {
		kind := Event_Kind.Modified
		if fi.inode != w.prev.inode {
			kind = .Renamed
		}
		w.prev = fi
		return Event{kind = kind, path = strings.clone(w.path, w.allocator)}, true
	}
	return {}, false
}

// get_event_file_poll pops the next event from the watcher's events buffer.
// If empty, performs one stat() check and returns the result.
get_event_file_poll :: proc(w: ^Watcher_File_Poll) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return poll_file_get_event(w)
}

// get_events_file_poll returns all available events from a Watcher_File_Poll.
get_events_file_poll :: proc(w: ^Watcher_File_Poll) -> []Event {
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)
	ev, ok := poll_file_get_event(w)
	if !ok do return nil
	append(&w.events, ev)
	return w.events[:]
}

// poll_dir_get_events performs a single snapshot diff of a directory and fills
// the watcher's events buffer. Returns the buffer as a slice.
poll_dir_get_events :: proc(w: ^Watcher_Dir_Poll) -> []Event {
	// Free old event paths
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)

	old := w.prev
	current := make(map[string]File_Info, w.allocator)
	snapshot_dir_alloc(w.path, &current, w.allocator)

	// Find removed (in old, not in current)
	for path in old {
		if _, ok := current[path]; !ok {
			append(&w.events, Event{kind = .Removed, path = strings.clone(path, w.allocator)})
		}
	}

	// Find added/modified
	for path, fi in current {
		prev, ok := old[path]
		if !ok {
			append(&w.events, Event{kind = .Added, path = strings.clone(path, w.allocator), is_dir = fi.is_dir})
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			append(&w.events, Event{kind = .Modified, path = strings.clone(path, w.allocator), is_dir = fi.is_dir})
		}
	}

	// Free old prev keys
	for path in old {
		delete(path, w.allocator)
	}
	delete(old)
	w.prev = current

	if len(w.events) == 0 do return nil
	return w.events[:]
}

poll_dir_get_event :: proc(w: ^Watcher_Dir_Poll) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	_ = poll_dir_get_events(w)
	if len(w.events) == 0 do return {}, false
	return pop(&w.events), true
}

// get_event_dir_poll returns the next event from a Watcher_Dir_Poll.
get_event_dir_poll :: proc(w: ^Watcher_Dir_Poll) -> (Event, bool) {
	return poll_dir_get_event(w)
}

// get_events_dir_poll returns all available events from a Watcher_Dir_Poll.
get_events_dir_poll :: proc(w: ^Watcher_Dir_Poll) -> []Event {
	return poll_dir_get_events(w)
}

poll_rec_get_events :: proc(w: ^Watcher_Recursive_Poll) -> []Event {
	// Free old event paths
	for e in w.events {
		delete(e.path, w.allocator)
	}
	clear(&w.events)

	old := w.prev
	current := make(map[string]File_Info, w.allocator)
	snapshot_recursive_alloc(w.path, &current, w.allocator)

	// Find removed
	for path in old {
		if _, ok := current[path]; !ok {
			append(&w.events, Event{kind = .Removed, path = strings.clone(path, w.allocator)})
		}
	}

	// Find added/modified
	for path, fi in current {
		prev, ok := old[path]
		if !ok {
			append(&w.events, Event{kind = .Added, path = strings.clone(path, w.allocator), is_dir = fi.is_dir})
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			append(&w.events, Event{kind = .Modified, path = strings.clone(path, w.allocator), is_dir = fi.is_dir})
		}
	}

	// Free old prev keys
	for path in old {
		delete(path, w.allocator)
	}
	delete(old)
	w.prev = current

	if len(w.events) == 0 do return nil
	return w.events[:]
}

poll_rec_get_event :: proc(w: ^Watcher_Recursive_Poll) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	_ = poll_rec_get_events(w)
	if len(w.events) == 0 do return {}, false
	return pop(&w.events), true
}

// get_event_rec_poll returns the next event from a Watcher_Recursive_Poll.
get_event_rec_poll :: proc(w: ^Watcher_Recursive_Poll) -> (Event, bool) {
	return poll_rec_get_event(w)
}

// get_events_rec_poll returns all available events from a Watcher_Recursive_Poll.
get_events_rec_poll :: proc(w: ^Watcher_Recursive_Poll) -> []Event {
	return poll_rec_get_events(w)
}
