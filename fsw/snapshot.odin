package fsw

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

File_Info :: struct {
	is_dir: bool,
	size:   i64,
	mtime:  time.Time,
	inode:  u128,
}

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

snapshot_dir :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		fullpath := filepath.join({dir, entry.name}, context.temp_allocator) or_continue
		prev[fullpath] = File_Info{
			is_dir = entry.type == .Directory,
			size   = entry.size,
			mtime  = entry.modification_time,
			inode  = entry.inode,
		}
	}
}

snapshot_recursive :: proc(dir: string, prev: ^map[string]File_Info, allocator: mem.Allocator) {
	snapshot_dir(dir, prev, allocator)
	// Snapshot subdirs
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		if entry.type == .Directory {
			subdir := filepath.join({dir, entry.name}, context.temp_allocator) or_continue
			snapshot_recursive(subdir, prev, allocator)
		}
	}
}

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
