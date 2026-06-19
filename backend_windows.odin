// backend_windows.odin — Windows backend using ReadDirectoryChangesW + IOCP.
//
// Platform-specific backend compiled only on Windows.
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.
//
// Pull-based architecture:
//   - Directories are opened with CreateFileW(FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OVERLAPPED)
//   - An I/O completion port is created with CreateIoCompletionPort
//   - ReadDirectoryChangesW is issued with an OVERLAPPED + event handle
//   - backend_*_get_event(s) procs do a non-blocking GetQueuedCompletionStatus (50ms timeout)
//     and parse the FILE_NOTIFY_INFORMATION entries
//   - File watcher: watches the parent directory, filters events by target filename
//   - Recursive watcher: uses bWatchSubtree=TRUE for OS-level recursion

package fsw

import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

// === Platform-specific native data ===
// The Native_* structs hold Windows HANDLEs for the directory, event, IOCP,
// notification buffer, and OVERLAPPED structure.

Native_File :: struct {
	handle:     windows.HANDLE,  // directory handle
	event:      windows.HANDLE,  // event handle
	iocp:       windows.HANDLE,  // IOCP handle
	buf:        [^]u8,           // notification buffer
	buf_len:    int,
	overlapped: ^windows.OVERLAPPED,
	target:     string, // filename to filter for file watcher
}

Native_Dir :: struct {
	handle:     windows.HANDLE,
	event:      windows.HANDLE,
	iocp:       windows.HANDLE,
	buf:        [^]u8,
	buf_len:    int,
	overlapped: ^windows.OVERLAPPED,
}

Native_Recursive :: struct {
	handle:     windows.HANDLE,
	event:      windows.HANDLE,
	iocp:       windows.HANDLE,
	buf:        [^]u8,
	buf_len:    int,
	overlapped: ^windows.OVERLAPPED,
}

@(private)
NOTIFY_FILTER :: (
    windows.FILE_NOTIFY_CHANGE_FILE_NAME |
    windows.FILE_NOTIFY_CHANGE_DIR_NAME |
    windows.FILE_NOTIFY_CHANGE_SIZE |
    windows.FILE_NOTIFY_CHANGE_LAST_WRITE |
    windows.FILE_NOTIFY_CHANGE_ATTRIBUTES |
    windows.FILE_NOTIFY_CHANGE_CREATION
)

@(private)
action_normalize :: proc(action: windows.DWORD) -> Event_Kind {
	switch action {
	case windows.FILE_ACTION_ADDED:            return .Added
	case windows.FILE_ACTION_REMOVED:          return .Removed
	case windows.FILE_ACTION_MODIFIED:         return .Modified
	case windows.FILE_ACTION_RENAMED_OLD_NAME: return .Renamed
	case windows.FILE_ACTION_RENAMED_NEW_NAME: return .Renamed
	case:                                      return .Modified
	}
}

@(private)
fni_name :: proc(entry: ^windows.FILE_NOTIFY_INFORMATION) -> string {
	if entry.file_name_length == 0 { return "" }
	name_ptr := rawptr(&entry.file_name[0])
	name_u16 := ([^]u16)(name_ptr)
	name_len := int(entry.file_name_length) / 2
	slice := name_u16[:name_len]
	buf := make([]u8, len(slice)*4, context.temp_allocator)
	s := windows.utf16_to_utf8_buf(buf, slice)
	return strings.clone(s, context.temp_allocator)
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	dir, base := filepath.split(w.path)
	_ = base
	dir = dir if dir != "" else "."

	wpath := windows.utf8_to_wstring_alloc(dir, context.temp_allocator)
	if wpath == nil { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil {
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		windows.CloseHandle(event)
		windows.CloseHandle(handle)
		free(overlapped, w.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 4096, w.allocator)
	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	w.native.handle = handle
	w.native.event = event
	w.native.iocp = iocp
	w.native.buf = raw_data(buf)
	w.native.buf_len = len(buf)
	w.native.overlapped = overlapped
	w.native.target = filepath.base(w.path)
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
}

backend_file_get_event :: proc(w: ^Watcher_File) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return iocp_read_file(w, &w.events, w.allocator, false)
}

backend_file_get_events :: proc(w: ^Watcher_File) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = iocp_read_file(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	wpath := windows.utf8_to_wstring_alloc(w.path, context.temp_allocator)
	if wpath == nil { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil {
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		windows.CloseHandle(event)
		windows.CloseHandle(handle)
		free(overlapped, w.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 4096, w.allocator)
	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	w.native.handle = handle
	w.native.event = event
	w.native.iocp = iocp
	w.native.buf = raw_data(buf)
	w.native.buf_len = len(buf)
	w.native.overlapped = overlapped
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
}

backend_dir_get_event :: proc(w: ^Watcher_Dir) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return iocp_read_dir(w, &w.events, w.allocator, false)
}

backend_dir_get_events :: proc(w: ^Watcher_Dir) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = iocp_read_dir(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	wpath := windows.utf8_to_wstring_alloc(w.path, context.temp_allocator)
	if wpath == nil { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil {
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		windows.CloseHandle(event)
		windows.CloseHandle(handle)
		free(overlapped, w.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 8192, w.allocator)
	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)

	w.native.handle = handle
	w.native.event = event
	w.native.iocp = iocp
	w.native.buf = raw_data(buf)
	w.native.buf_len = len(buf)
	w.native.overlapped = overlapped
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
}

backend_rec_native_cleanup :: proc(w: ^Watcher_Recursive) {
	// Windows uses ReadDirectoryChangesW with bWatchSubtree=TRUE, so
	// there's no per-subdirectory state to clean up.
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	// Windows ReadDirectoryChangesW with bWatchSubtree=TRUE
	// automatically tracks new/deleted subdirectories.
	return .None
}

backend_rec_get_event :: proc(w: ^Watcher_Recursive) -> (Event, bool) {
	if len(w.events) > 0 {
		return pop(&w.events), true
	}
	return iocp_read_rec(w, &w.events, w.allocator, false)
}

backend_rec_get_events :: proc(w: ^Watcher_Recursive) -> []Event {
	for e in w.events { delete(e.path, w.allocator) }
	clear(&w.events)
	_, _ = iocp_read_rec(w, &w.events, w.allocator, true)
	if len(w.events) == 0 do return nil
	return w.events[:]
}

// === Shared IOCP read helpers ===

// iocp_drain consumes pending IOCP completion events from the buffer at
// w.native.buf. Returns true if any events were found. Re-issues
// ReadDirectoryChangesW after each completed (or errored) call so the
// watcher stays responsive. The events are appended to `out`.
@(private)
iocp_drain :: proc(
	w: ^$T,
	out: ^[dynamic]Event,
	allocator: mem.Allocator,
	drain: bool,
	process: proc(entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^T, allocator: mem.Allocator) -> (Event, bool),
) -> (Event, bool) {
	handle := w.native.handle
	iocp := w.native.iocp
	event := w.native.event
	buf := w.native.buf[:w.native.buf_len]
	overlapped := w.native.overlapped

	got_one: bool
	first: Event
	for {
		bytes: windows.DWORD = 0
		key: windows.ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		_ = windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)

		// If no completion was dequeued (timeout), keep waiting with the
		// existing pending request.
		if overlapped_out == nil {
			break
		}

		if bytes > 0 {
			entry := cast(^windows.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				e, matched := process(entry, w, allocator)
				if matched {
					if drain {
						append(out, e)
						got_one = true
					} else if !got_one {
						first = e
						got_one = true
					}
				}
				if entry.next_entry_offset == 0 { break }
				entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}

		// A completion (success or error) dequeued the pending request.
		// Re-issue so we get more events.
		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
		if !drain do break
	}
	if !drain do return first, got_one
	return {}, got_one
}

@(private)
process_file_entry :: proc(entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_File, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	if name == w.native.target {
		kind := action_normalize(entry.action)
		return Event{kind = kind, path = strings.clone(w.path, allocator)}, true
	}
	return {}, false
}

@(private)
process_dir_entry :: proc(entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_Dir, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	kind := action_normalize(entry.action)
	fullpath := strings.clone(w.path, allocator)
	if name != "" {
		joined, _ := filepath.join({w.path, name}, allocator)
		delete(fullpath, allocator)
		fullpath = joined
	}
	return Event{kind = kind, path = fullpath}, true
}

@(private)
process_rec_entry :: proc(entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_Recursive, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	kind := action_normalize(entry.action)
	fullpath := strings.clone(w.path, allocator)
	if name != "" {
		joined, _ := filepath.join({w.path, name}, allocator)
		delete(fullpath, allocator)
		fullpath = joined
	}
	return Event{kind = kind, path = fullpath}, true
}

@(private)
iocp_read_file :: proc(w: ^Watcher_File, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	return iocp_drain(w, out, allocator, drain, process_file_entry)
}

@(private)
iocp_read_dir :: proc(w: ^Watcher_Dir, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	return iocp_drain(w, out, allocator, drain, process_dir_entry)
}

@(private)
iocp_read_rec :: proc(w: ^Watcher_Recursive, out: ^[dynamic]Event, allocator: mem.Allocator, drain: bool) -> (Event, bool) {
	return iocp_drain(w, out, allocator, drain, process_rec_entry)
}
