// snapshot.odin — Stat-based file snapshots and diffing for polling watchers.
//
// Internal helpers used by the polling backends and the kqueue backends:
//   - File_Info: lightweight stat record (is_dir, size, mtime, inode)
//   - file_stat_alloc: stat a path into a raw os.File_Info
//   - snapshot_dir_alloc / snapshot_recursive_alloc: populate a map with
//     File_Info entries (full path keys), the recursive variant recurses
//     into subdirectories
//   - snapshot_dir_by_name_alloc: same but keyed by entry name (used by
//     kqueue backends that diff by filename)
//
// These are not part of the public API.

package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// File_Info is a lightweight stat record used by polling watchers to detect changes.
File_Info :: struct {
	is_dir: bool,
	size:   i64,
	mtime:  time.Time,
	inode:  u128,
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

// snapshot_dir_alloc populates a map with File_Info entries for all files in a
// directory. All allocations use the provided allocator. Callers are
// responsible for freeing the map keys.
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

// snapshot_recursive_alloc populates a map with File_Info entries for all files
// in a directory tree. All allocations use the provided allocator.
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

// snapshot_dir_by_name_alloc populates a map keyed by entry name (not full path).
// Used by kqueue backends that detect changes via dir-level VNode events and
// need to diff by filename. Callers are responsible for freeing the map keys.
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
		// Clone the name since it is a slice into entry.fullpath, which
		// will be freed when the defer above runs. The map keys must
		// outlive the entries.
		name := strings.clone(entry.name, allocator)
		prev[name] = File_Info{
			is_dir = entry.type == .Directory,
			size   = entry.size,
			mtime  = entry.modification_time,
			inode  = entry.inode,
		}
	}
}
