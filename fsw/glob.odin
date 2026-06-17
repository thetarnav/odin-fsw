// glob.odin — Glob pattern matching and Watcher_Glob support logic.
//
// Internal helpers for the glob watcher:
//   - glob_extract_root: split a glob pattern into a static directory root and the pattern remainder
//   - glob_match_path: test a relative path against a glob pattern
//   - glob_initial_scan / glob_scan_dir: walk the watch root and populate matched_files
//   - glob_rescan: full re-scan on rescan, emitting Added/Removed events for changes
//   - glob_filter_event: filter recursive watcher events through the glob pattern
//   - glob_inner_callback: no-op placeholder (actual filtering happens in backend threads)
//
// The glob watcher works by embedding a Watcher_Recursive and routing its events
// through glob_filter_event. The backend thread checks user_data to decide routing.

package fsw

import "core:os"
import "core:path/filepath"
import "core:strings"

glob_extract_root :: proc(pattern: string) -> (root: string, remainder: string) {
	// Find the longest static prefix before the first wildcard.
	i := 0
	for i < len(pattern) {
		c := pattern[i]
		if c == '*' || c == '?' || c == '{' || c == '[' {
			break
		}
		if c == '/' || c == '\\' {
			// Include the separator in the root
			i += 1
			continue
		}
		i += 1
	}
	if i == 0 {
		return ".", pattern
	}
	root = pattern[:i]
	// Trim trailing separator
	if len(root) > 0 && (root[len(root)-1] == '/' || root[len(root)-1] == '\\') {
		root = root[:len(root)-1]
	}
	if root == "" {
		root = "."
	}
	remainder = pattern[i:]
	return
}

glob_match_path :: proc(pattern: string, path: string) -> bool {
	ok, _ := filepath.match(pattern, path)
	return ok
}

glob_inner_callback :: proc(event: ^Event) {
	// This is called by the inner Watcher_Recursive.
	// We need to recover the Watcher_Glob pointer from user_data.
	// The inner watcher's user_data points to the Watcher_Glob.
	// But how do we get the inner watcher pointer here?
	// The callback is invoked from the inotify thread with the event.
	// We don't have a direct reference to the inner watcher.
	// 
	// Solution: the inner watcher's user_data = ^Watcher_Glob.
	// We need to get the inner watcher pointer somehow.
	// Since the callback proc is a package-level proc (not a closure),
	// we can't capture the watcher pointer.
	//
	// Workaround: use a thread-local or global variable.
	// Better: the inner watcher's callback should be set to a proc
	// that knows the glob watcher pointer. We can do this by having
	// the inner watcher's thread check user_data.
	//
	// Actually, the simplest approach: we change the callback to be
	// called from the inner thread with access to the watcher struct.
	// Since the inner watcher's callback is set before the thread starts,
	// and the thread has access to the watcher via t.data,
	// we can have the thread call a wrapper that extracts user_data.
	//
	// But the callback is set on the Watcher_Recursive struct, not the thread.
	// The thread calls w.callback(event) where w is the Watcher_Recursive.
	// So the callback doesn't have access to w itself.
	//
	// FINAL APPROACH: Don't use this callback. Instead, the recursive
	// thread calls a special internal proc that checks if user_data is set.
	// If so, it wraps the event through the glob filter.
	//
	// For now, this is a no-op. The actual glob filtering happens in
	// inotify_rec_thread when it detects user_data is set.
	_ = event
}

glob_initial_scan :: proc(w: ^Watcher_Glob) {
	// Walk the watch root, find all files matching the pattern,
	// and populate matched_files.
	glob_scan_dir(w, w.inner.path)
}

glob_scan_dir :: proc(w: ^Watcher_Glob, dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		fullpath, join_err := filepath.join({dir, entry.name}, w.allocator)
		if join_err != nil do continue
		rel, rel_err := filepath.rel(w.inner.path, fullpath, context.temp_allocator)
		if rel_err != nil {
			delete(fullpath, w.allocator)
			continue
		}
		if entry.type == .Directory {
			glob_scan_dir(w, fullpath)
		}
		if glob_match_path(w.pattern, rel) {
			w.matched_files[fullpath] = true
		} else {
			delete(fullpath, w.allocator)
		}
	}
}

glob_rescan :: proc(w: ^Watcher_Glob) {
	old := w.matched_files
	w.matched_files = make(map[string]bool, w.allocator)
	glob_scan_dir(w, w.inner.path)
	for path in old {
		if _, ok := w.matched_files[path]; !ok {
			e := Event{kind = .Removed, path = path}
			invoke_callback_glob(w, &e)
		}
	}
	for path in w.matched_files {
		if _, ok := old[path]; !ok {
			e := Event{kind = .Added, path = path}
			invoke_callback_glob(w, &e)
		}
	}
	for path in old {
		delete(path, w.allocator)
	}
	delete(old)
}

// === Internal callback used by the recursive watcher thread ===
// This is called from inotify_rec_thread when user_data is non-nil.
// It filters events through the glob pattern.

glob_filter_event :: proc(gw: ^Watcher_Glob, event: ^Event) {
	rel, rel_err := filepath.rel(gw.inner.path, event.path, context.temp_allocator)
	if rel_err != nil do return

	#partial switch event.kind {
	case .Added:
		if !event.is_dir && glob_match_path(gw.pattern, rel) {
			path_clone := strings.clone(event.path, gw.allocator)
			gw.matched_files[path_clone] = true
			e := Event{kind = .Added, path = path_clone}
			invoke_callback_glob(gw, &e)
		}
	case .Removed:
		for key in gw.matched_files {
			if key == event.path {
				delete_key(&gw.matched_files, key)
				delete(key, gw.allocator)
				e := Event{kind = .Removed, path = event.path}
				invoke_callback_glob(gw, &e)
				break
			}
		}
	case .Modified:
		if _, ok := gw.matched_files[event.path]; ok {
			e := Event{kind = .Modified, path = event.path}
			invoke_callback_glob(gw, &e)
		}
	case .Renamed:
		for key in gw.matched_files {
			if key == event.path {
				delete_key(&gw.matched_files, key)
				delete(key, gw.allocator)
				e := Event{kind = .Removed, path = event.path}
				invoke_callback_glob(gw, &e)
				break
			}
		}
	case:
	}
}
