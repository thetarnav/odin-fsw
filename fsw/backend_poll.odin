// backend_poll.odin — Polling backend for all platforms.
//
// Stat-based polling fallback that works on every platform. Used by:
//   - Watcher_File_Poll: polls a single file with file_stat()
//   - Watcher_Dir_Poll: snapshot-diffs a directory each interval
//   - Watcher_Recursive_Poll: snapshot-diffs recursively each interval
//
// Each watcher type has a dedicated thread proc (poll_file_thread, poll_dir_thread,
// poll_rec_thread) that loops sleeping w.latency between checks. The start_poll_*
// helpers create and start these threads.
//
// File deletion is tracked via a prev.size < 0 sentinel. When a file disappears,
// a .Removed event fires; when it reappears, .Added fires.

package fsw

import "core:thread"
import "core:time"

poll_file_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_File_Poll)(t.data)
	for w.running {
		fi, err := file_stat(w.path)
		if err != .None {
			if w.prev.size >= 0 {
				e := Event{kind = .Removed, path = w.path}
				invoke_callback_file_poll(w, &e)
				w.prev = File_Info{size = -1}
			}
			time.sleep(w.latency)
			continue
		}
		if w.prev.size < 0 {
			e := Event{kind = .Added, path = w.path}
			invoke_callback_file_poll(w, &e)
			w.prev = fi
			time.sleep(w.latency)
			continue
		}
		changed := fi.mtime != w.prev.mtime || fi.size != w.prev.size || fi.inode != w.prev.inode
		if changed {
			kind := Event_Kind.Modified
			if fi.inode != w.prev.inode {
				kind = .Renamed
			}
			e := Event{kind = kind, path = w.path}
			invoke_callback_file_poll(w, &e)
			w.prev = fi
		}
		time.sleep(w.latency)
	}
}

poll_dir_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Dir_Poll)(t.data)
	for w.running {
		current := make(map[string]File_Info, w.allocator)
		snapshot_dir(w.path, &current, w.allocator)

		for path in w.prev {
			if _, ok := current[path]; !ok {
				e := Event{kind = .Removed, path = path}
				invoke_callback_dir_poll(w, &e)
			}
		}

		for path, fi in current {
			prev, ok := w.prev[path]
			if !ok {
				e := Event{kind = .Added, path = path, is_dir = fi.is_dir}
				invoke_callback_dir_poll(w, &e)
			} else if fi.mtime != prev.mtime || fi.size != prev.size {
				e := Event{kind = .Modified, path = path, is_dir = fi.is_dir}
				invoke_callback_dir_poll(w, &e)
			}
		}

		delete(w.prev)
		w.prev = current
		time.sleep(w.latency)
	}
}

poll_rec_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Recursive_Poll)(t.data)
	for w.running {
		current := make(map[string]File_Info, w.allocator)
		snapshot_recursive(w.path, &current, w.allocator)

		for path in w.prev {
			if _, ok := current[path]; !ok {
				e := Event{kind = .Removed, path = path}
				invoke_callback_rec_poll(w, &e)
			}
		}

		for path, fi in current {
			prev, ok := w.prev[path]
			if !ok {
				e := Event{kind = .Added, path = path, is_dir = fi.is_dir}
				invoke_callback_rec_poll(w, &e)
			} else if fi.mtime != prev.mtime || fi.size != prev.size {
				e := Event{kind = .Modified, path = path, is_dir = fi.is_dir}
				invoke_callback_rec_poll(w, &e)
			}
		}

		delete(w.prev)
		w.prev = current
		time.sleep(w.latency)
	}
}

start_poll_file_thread :: proc(w: ^Watcher_File_Poll) -> ^thread.Thread {
	t := thread.create(poll_file_thread)
	t.data = w
	thread.start(t)
	return t
}

start_poll_dir_thread :: proc(w: ^Watcher_Dir_Poll) -> ^thread.Thread {
	t := thread.create(poll_dir_thread)
	t.data = w
	thread.start(t)
	return t
}

start_poll_rec_thread :: proc(w: ^Watcher_Recursive_Poll) -> ^thread.Thread {
	t := thread.create(poll_rec_thread)
	t.data = w
	thread.start(t)
	return t
}
