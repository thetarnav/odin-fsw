// snapshot.odin — Stat-based file snapshots and diffing for polling watchers.
//
// Internal helpers used by the polling backends:
//   - File_Info: lightweight stat record (is_dir, size, mtime, inode)
//   - file_stat: stat a single path into a File_Info
//   - snapshot_dir: populate a map with File_Info entries for a directory
//   - snapshot_recursive: recursive version of snapshot_dir
//   - diff_file: compare a path against a previous File_Info, return the event kind
//
// These are not part of the public API but are used by backend_poll.odin.

package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

// File_Info is a lightweight stat record used by polling watchers to detect changes.
File_Info :: struct {
	is_dir: bool,
	size:   i64,
	mtime:  time.Time,
	inode:  u128,
}

// file_stat stats a path and returns a File_Info. Returns .Invalid_Path on error.
file_stat :: proc(path: string) -> (fi: File_Info, err: Error) {
	s, e := os.stat(path, context.temp_allocator)
	if e != nil {
		return {}, .Invalid_Path
	}
	return File_Info{
		is_dir = s.type == .Directory,
		size   = s.size,
		mtime  = s.modification_time,
		inode  = s.inode,
	}, .None
}

// file_stat_alloc stats a path using the provided allocator. The caller is
// responsible for freeing the returned os.File_Info via os.file_info_delete.
file_stat_alloc :: proc(path: string, allocator: mem.Allocator) -> (os.File_Info, Error) {
	info, e := os.stat(path, allocator)
	if e != nil {
		return {}, .Invalid_Path
	}
	return info, .None
}

// snapshot_dir populates a map with File_Info entries for all files in a directory.
snapshot_dir :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	snapshot_dir_alloc(dir, prev, allocator)
}

// snapshot_dir_alloc populates a map with File_Info entries for all files in a directory.
// All allocations use the provided allocator. Callers are responsible for freeing
// the map keys.
snapshot_dir_alloc :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return
	defer {
		for entry in entries {
			os.file_info_delete(entry, allocator)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		fullpath := filepath.join({dir, entry.name}, allocator) or_continue
		prev[fullpath] = File_Info{
			is_dir = entry.type == .Directory,
			size   = entry.size,
			mtime  = entry.modification_time,
			inode  = entry.inode,
		}
	}
}

// snapshot_recursive populates a map with File_Info entries for all files in a directory tree.
snapshot_recursive :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	snapshot_recursive_alloc(dir, prev, allocator)
}

// snapshot_recursive_alloc populates a map with File_Info entries for all files in a
// directory tree. All allocations use the provided allocator.
snapshot_recursive_alloc :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return
	defer {
		for entry in entries {
			os.file_info_delete(entry, allocator)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		fullpath := filepath.join({dir, entry.name}, allocator) or_continue
		prev[fullpath] = File_Info{
			is_dir = entry.type == .Directory,
			size   = entry.size,
			mtime  = entry.modification_time,
			inode  = entry.inode,
		}
		if entry.type == .Directory {
			snapshot_recursive_alloc(fullpath, prev, allocator)
		}
	}
}

// snapshot_dir_by_name populates a map keyed by entry name (not full path).
// Used by kqueue backends that detect changes via dir-level VNode events
// and need to diff by filename.
snapshot_dir_by_name :: proc(dir: string, prev: ^map[string]File_Info) {
	snapshot_dir_by_name_alloc(dir, prev, context.temp_allocator)
}

// snapshot_dir_by_name_alloc is the same as snapshot_dir_by_name but uses the
// given allocator. Callers are responsible for freeing the map keys.
snapshot_dir_by_name_alloc :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return
	defer {
		for entry in entries {
			os.file_info_delete(entry, allocator)
		}
		delete(entries)
	}
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		prev[entry.name] = File_Info{
			is_dir = entry.type == .Directory,
			size   = entry.size,
			mtime  = entry.modification_time,
			inode  = entry.inode,
		}
	}
}

// diff_file compares a path's current state against a previous File_Info.
// Returns the event kind, new info, and whether a change was detected.
diff_file :: proc(path: string, prev: File_Info) -> (kind: Event_Kind, new_fi: File_Info, changed: bool) {
	fi, err := file_stat(path)
	if err != .None {
		return .Removed, {}, true
	}
	if fi.mtime != prev.mtime || fi.size != prev.size {
		return .Modified, fi, true
	}
	if fi.inode != prev.inode {
		return .Renamed, fi, true
	}
	return .Modified, fi, false
}
