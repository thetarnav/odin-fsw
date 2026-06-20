// backend_windows.odin — Windows backend using IOCP + ReadDirectoryChangesW.
//
// Platform-specific backend compiled only on Windows.
// Pull-based: each get_events call does one non-blocking IOCP drain and
// re-issues the pending ReadDirectoryChangesW, appending all events to
// the caller's dynamic array.
//
//   - Directories are opened with CreateFileW(FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OVERLAPPED)
//   - An I/O completion port is created with CreateIoCompletionPort
//   - ReadDirectoryChangesW issues a single pending request; GetQueuedCompletionStatus
//     with a 0ms timeout polls for completions

#+private package
package fsw

import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

NOTIFY_FILTER :: windows.FILE_NOTIFY_CHANGE_FILE_NAME   |
                windows.FILE_NOTIFY_CHANGE_DIR_NAME    |
                windows.FILE_NOTIFY_CHANGE_ATTRIBUTES  |
                windows.FILE_NOTIFY_CHANGE_SIZE       |
                windows.FILE_NOTIFY_CHANGE_LAST_WRITE

Native_File :: struct {
	handle:     windows.HANDLE,
	event:      windows.HANDLE,
	iocp:       windows.HANDLE,
	buf:        [^]u8,
	buf_len:    int,
	overlapped: ^windows.OVERLAPPED,
	target:     string,
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

// === Watcher_File ===

backend_file_init :: proc (w: ^Watcher_File) -> (err: Error) {

	track_start(w)

	dir, base := filepath.split(w.path)
	_ = base
	dir = dir if dir != "" else "."

	wpath := windows.utf8_to_wstring_alloc(dir, context.temp_allocator)
	if wpath == nil do return .Backend_Init_Failed

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE do return .Backend_Init_Failed
	track_open(w, uintptr(handle))
	defer if err != nil {
		windows.CloseHandle(handle)
		track_close(w, uintptr(handle))
	}

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil do return .Backend_Init_Failed
	track_open(w, int(uintptr(event)))
	defer if err != nil {
		windows.CloseHandle(event)
		track_close(w, int(uintptr(event)))
	}

	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event
	defer if err != nil {
		free(overlapped, w.allocator)
	}

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil do return .Backend_Init_Failed
	track_open(w, uintptr(iocp))

	buf := make([]u8, 4096, w.allocator)
	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	w.native.handle     = handle
	w.native.event      = event
	w.native.iocp       = iocp
	w.native.buf        = raw_data(buf)
	w.native.buf_len    = len(buf)
	w.native.overlapped = overlapped
	w.native.target     = filepath.base(w.path)
	return .None
}

backend_file_destroy :: proc (w: ^Watcher_File) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
		track_close(w, uintptr(w.native.iocp))
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
		track_close(w, int(uintptr(w.native.event)))
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
		track_close(w, uintptr(w.native.handle))
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
	track_end(w)
}

backend_file_get_events :: proc (w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	iocp_drain_file(w, allocator, out)
}

// === Watcher_Dir ===

backend_dir_init :: proc (w: ^Watcher_Dir) -> Error {

	track_start(w)

	wpath := windows.utf8_to_wstring_alloc(w.path, context.temp_allocator)
	if wpath == nil do return .Backend_Init_Failed

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE do return .Backend_Init_Failed
	track_open(w, int(uintptr(handle)))

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil {
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	track_open(w, int(uintptr(event)))
	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		windows.CloseHandle(event)
		track_close(w, int(uintptr(event)))
		windows.CloseHandle(handle)
		track_close(w, int(uintptr(handle)))
		free(overlapped, w.allocator)
		return .Backend_Init_Failed
	}
	track_open(w, int(uintptr(iocp)))

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

backend_dir_destroy :: proc (w: ^Watcher_Dir) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
		track_close(w, int(uintptr(w.native.iocp)))
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
		track_close(w, int(uintptr(w.native.event)))
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
		track_close(w, int(uintptr(w.native.handle)))
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
	track_end(w)
}

backend_dir_get_events :: proc (w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	iocp_drain_dir(w, allocator, out)
}

// === Watcher_Recursive ===

backend_rec_init :: proc (w: ^Watcher_Recursive) -> Error {

	track_start(w)

	wpath := windows.utf8_to_wstring_alloc(w.path, context.temp_allocator)
	if wpath == nil do return .Backend_Init_Failed

	handle := windows.CreateFileW(
		wpath,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == windows.INVALID_HANDLE_VALUE do return .Backend_Init_Failed
	track_open(w, int(uintptr(handle)))

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil {
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	track_open(w, int(uintptr(event)))
	overlapped := new(windows.OVERLAPPED, w.allocator)
	overlapped.hEvent = event

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		windows.CloseHandle(event)
		track_close(w, int(uintptr(event)))
		windows.CloseHandle(handle)
		track_close(w, int(uintptr(handle)))
		free(overlapped, w.allocator)
		return .Backend_Init_Failed
	}
	track_open(w, int(uintptr(iocp)))

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

backend_rec_destroy :: proc (w: ^Watcher_Recursive) {
	if w.native.iocp != nil {
		windows.CloseHandle(w.native.iocp)
		track_close(w, int(uintptr(w.native.iocp)))
	}
	if w.native.event != nil {
		windows.CloseHandle(w.native.event)
		track_close(w, int(uintptr(w.native.event)))
	}
	if w.native.handle != nil {
		windows.CloseHandle(w.native.handle)
		track_close(w, int(uintptr(w.native.handle)))
	}
	if w.native.overlapped != nil {
		free(w.native.overlapped, w.allocator)
	}
	if w.native.buf != nil {
		delete(w.native.buf[:w.native.buf_len], w.allocator)
	}
	track_end(w)
}

backend_rec_native_cleanup :: proc (w: ^Watcher_Recursive) {
	// Windows uses ReadDirectoryChangesW with bWatchSubtree=TRUE, so
	// there's no per-subdirectory state to clean up.
}

backend_rec_rescan :: proc (w: ^Watcher_Recursive) -> Error {
	// Windows ReadDirectoryChangesW with bWatchSubtree=TRUE
	// automatically tracks new/deleted subdirectories.
	return .None
}

backend_rec_get_events :: proc (w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	iocp_drain_rec(w, allocator, out)
}

// === Shared IOCP read helpers ===

iocp_drain_file :: proc (w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	handle     := w.native.handle
	iocp       := w.native.iocp
	event      := w.native.event
	buf        := w.native.buf[:w.native.buf_len]
	overlapped := w.native.overlapped

	for {
		bytes: windows.DWORD = 0
		key: windows.ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if overlapped_out == nil do break

		if bytes > 0 {
			entry := (^windows.FILE_NOTIFY_INFORMATION)(&buf[0])
			for {
				e: Event
				matched: bool
				e, matched = process_file_entry(entry, w, allocator)
				if matched do append(out, e)
				if entry.next_entry_offset == 0 do break
				entry = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(entry) + uintptr(entry.next_entry_offset))
			}
		}

		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

iocp_drain_dir :: proc (w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	handle     := w.native.handle
	iocp       := w.native.iocp
	event      := w.native.event
	buf        := w.native.buf[:w.native.buf_len]
	overlapped := w.native.overlapped

	for {
		bytes: windows.DWORD = 0
		key: windows.ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if overlapped_out == nil do break

		if bytes > 0 {
			entry := (^windows.FILE_NOTIFY_INFORMATION)(&buf[0])
			for {
				e: Event
				matched: bool
				e, matched = process_dir_entry(entry, w, allocator)
				if matched do append(out, e)
				if entry.next_entry_offset == 0 do break
				entry = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(entry) + uintptr(entry.next_entry_offset))
			}
		}

		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

iocp_drain_rec :: proc (w: ^Watcher_Recursive, allocator: mem.Allocator, out: ^[dynamic]Event) {
	handle     := w.native.handle
	iocp       := w.native.iocp
	event      := w.native.event
	buf        := w.native.buf[:w.native.buf_len]
	overlapped := w.native.overlapped

	for {
		bytes: windows.DWORD = 0
		key: windows.ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if overlapped_out == nil do break

		if bytes > 0 {
			entry := (^windows.FILE_NOTIFY_INFORMATION)(&buf[0])
			for {
				e: Event
				matched: bool
				e, matched = process_rec_entry(entry, w, allocator)
				if matched do append(out, e)
				if entry.next_entry_offset == 0 do break
				entry = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(entry) + uintptr(entry.next_entry_offset))
			}
		}

		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

@require_results
process_file_entry :: proc (entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_File, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	if name == w.native.target {
		kind := action_normalize(entry.action)
		return Event{kind = kind, path = strings.clone(w.path, allocator)}, true
	}
	return {}, false
}

@require_results
process_dir_entry :: proc (entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_Dir, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	fullpath, _ := filepath.join({w.path, name}, allocator)
	return Event{
		kind = action_normalize(entry.action),
		path = fullpath,
		is_dir = entry.action == 3 || entry.action == 4,
	}, true
}

@require_results
process_rec_entry :: proc (entry: ^windows.FILE_NOTIFY_INFORMATION, w: ^Watcher_Recursive, allocator: mem.Allocator) -> (Event, bool) {
	name := fni_name(entry)
	fullpath, _ := filepath.join({w.path, name}, allocator)
	return Event{
		kind = action_normalize(entry.action),
		path = fullpath,
		is_dir = entry.action == 3 || entry.action == 4,
	}, true
}

@require_results
action_normalize :: proc (action: u32) -> Event_Kind {
	switch action {
	case 1: return .Added       // FILE_ACTION_ADDED
	case 2: return .Removed     // FILE_ACTION_REMOVED
	case 3: return .Modified    // FILE_ACTION_MODIFIED
	case 4: return .Renamed     // FILE_ACTION_RENAMED_OLD_NAME
	case 5: return .Renamed     // FILE_ACTION_RENAMED_NEW_NAME
	}
	return .Modified
}

@require_results
fni_name :: proc (entry: ^windows.FILE_NOTIFY_INFORMATION) -> string {
	if entry.file_name_length == 0 do return ""
	name_u16 := ([^]u16)(&entry.file_name[0])
	name_len := int(entry.file_name_length) / 2
	slice := name_u16[:name_len]
	buf := make([]u8, name_len*4, context.temp_allocator)
	s := windows.utf16_to_utf8_buf(buf, slice)
	return strings.clone(s, context.temp_allocator)
}
