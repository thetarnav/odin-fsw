// glob.odin — Glob pattern matching and Watcher_Glob support logic.
//
// Internal helpers for the glob watcher:
//   - glob_extract_root: split a glob pattern into a static directory root and the pattern remainder
//   - glob_match_path: test a relative path against a glob pattern
//   - glob_scan_dir: walk the watch root and populate matched_files
//   - glob_rescan: full re-scan on rescan, emitting Added/Removed events
//   - glob_get_events: pull events from the inner recursive watcher, filter, return

package fsw

import "core:os"
import "core:path/filepath"
import "core:strings"

glob_extract_root :: proc(pattern: string) -> (root: string, remainder: string) {
	i := 0
	for i < len(pattern) {
		c := pattern[i]
		if c == '*' || c == '?' || c == '{' || c == '[' {
			break
		}
		if c == '/' || c == '\\' {
			i += 1
			continue
		}
		i += 1
	}
	if i == 0 {
		return ".", pattern
	}
	root = pattern[:i]
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
			// .Removed events are emitted by get_events on the next call;
			// matched_files cleanup happens then.
			delete(path, w.allocator)
		}
	}
	delete(old)
}

// glob_get_events pulls events from the inner recursive watcher and applies
// the glob filter. Non-matching events are consumed and discarded; matching
// events are cloned and returned. The returned slice and its path strings
// are allocated with `allocator`.
glob_get_events :: proc(w: ^Watcher_Glob, allocator := context.allocator) -> []Event {

	inner_events := get_events(&w.inner, allocator)
	defer {
		for e in inner_events {
			delete(e.path, allocator)
		}
	}

	out := make([dynamic]Event, 0, len(inner_events), allocator)
	for &e in inner_events {
		key_path, matched := glob_filter_event(w, &e)
		if matched {
			append(&out, Event{kind = e.kind, path = strings.clone(key_path, allocator), is_dir = e.is_dir})
		}
	}
	shrink(&out)
	return out[:]
}

// glob_filter_event applies the glob pattern to the event and updates
// w.matched_files. Returns the (possibly stable) path key from matched_files
// to use as the event's path, and whether the event matches the pattern.
// The returned key_path is owned by matched_files and remains valid until
// that key is removed.
glob_filter_event :: proc(gw: ^Watcher_Glob, event: ^Event) -> (key_path: string, matched: bool) {
	rel, rel_err := filepath.rel(gw.inner.path, event.path, context.temp_allocator)
	if rel_err != nil do return "", false

	#partial switch event.kind {
	case .Added:
		if !event.is_dir && glob_match_path(gw.pattern, rel) {
			path_clone := strings.clone(event.path, gw.allocator)
			gw.matched_files[path_clone] = true
			return path_clone, true
		}
	case .Removed:
		for key in gw.matched_files {
			if key == event.path {
				delete_key(&gw.matched_files, key)
				delete(key, gw.allocator)
				return key, true
			}
		}
	case .Modified:
		if _, ok := gw.matched_files[event.path]; ok {
			return event.path, true
		}
	case .Renamed:
		for key in gw.matched_files {
			if key == event.path {
				delete_key(&gw.matched_files, key)
				delete(key, gw.allocator)
				return key, true
			}
		}
	case:
	}
	return "", false
}
