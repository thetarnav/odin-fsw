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
                 windows.FILE_NOTIFY_CHANGE_SIZE        |
                 windows.FILE_NOTIFY_CHANGE_LAST_WRITE

Native_Dir :: struct {
	handle:     windows.HANDLE,
	event:      windows.HANDLE,
	iocp:       windows.HANDLE,
	buf:        []u8,
	overlapped: windows.OVERLAPPED,
}

Native_File :: struct {
	using dir:  Native_Dir,
	target:     string,
}

Native_Recursive :: Native_Dir

// === Watcher_File ===

backend_file_init :: proc (w: ^Watcher_File) -> (err: Error) {

	track_start(w)

	dir, _ := filepath.split(w.path)
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
	track_open(w, uintptr(event))
	defer if err != nil {
		windows.CloseHandle(event)
		track_close(w, uintptr(event))
	}

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil do return .Backend_Init_Failed
	track_open(w, uintptr(iocp))

	w.overlapped = windows.OVERLAPPED{hEvent=event}
	w.buf        = make([]u8, 4096, w.allocator)
	w.handle     = handle
	w.event      = event
	w.iocp       = iocp
	w.target     = filepath.base(w.path)

	windows.ReadDirectoryChangesW(handle, raw_data(w.buf), windows.DWORD(len(w.buf)), false, NOTIFY_FILTER, nil, &w.overlapped, nil)

	return .None
}

backend_file_destroy :: proc (w: ^Watcher_File) {
	if w.iocp != nil {
		windows.CloseHandle(w.iocp)
		track_close(w, uintptr(w.iocp))
	}
	if w.event != nil {
		windows.CloseHandle(w.event)
		track_close(w, uintptr(w.event))
	}
	if w.handle != nil {
		windows.CloseHandle(w.handle)
		track_close(w, uintptr(w.handle))
	}
	if w.buf != nil {
		delete(w.buf, w.allocator)
	}
	track_end(w)
}

backend_file_get_events :: proc (w: ^Watcher_File, allocator: mem.Allocator, out: ^[dynamic]Event) {
	iocp_drain(w, allocator, out)
}

// === Watcher_Dir ===

backend_dir_init :: proc (w: ^Watcher_Dir) -> (err: Error) {

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
	track_open(w, uintptr(handle))
	defer if err != nil {
		windows.CloseHandle(handle)
		track_close(w, uintptr(handle))
	}

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil do return .Backend_Init_Failed
	track_open(w, uintptr(event))
	defer if err != nil {
		windows.CloseHandle(event)
		track_close(w, uintptr(event))
	}

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil do return .Backend_Init_Failed
	track_open(w, uintptr(iocp))

	w.overlapped = windows.OVERLAPPED{hEvent=event}
	w.buf        = make([]u8, 4096, w.allocator)
	w.handle     = handle
	w.event      = event
	w.iocp       = iocp

	windows.ReadDirectoryChangesW(handle, raw_data(w.buf), windows.DWORD(len(w.buf)), false, NOTIFY_FILTER, nil, &w.overlapped, nil)

	return .None
}

backend_dir_destroy :: proc (w: ^Watcher_Dir) {
	if w.iocp != nil {
		windows.CloseHandle(w.iocp)
		track_close(w, uintptr(w.iocp))
	}
	if w.event != nil {
		windows.CloseHandle(w.event)
		track_close(w, uintptr(w.event))
	}
	if w.handle != nil {
		windows.CloseHandle(w.handle)
		track_close(w, uintptr(w.handle))
	}
	if w.buf != nil {
		delete(w.buf, w.allocator)
	}
	track_end(w)
}

backend_dir_get_events :: proc (w: ^Watcher_Dir, allocator: mem.Allocator, out: ^[dynamic]Event) {
	iocp_drain(w, allocator, out)
}

// === Watcher_Recursive ===

backend_rec_init :: proc (w: ^Watcher_Recursive) -> (err: Error) {

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
	track_open(w, uintptr(handle))
	defer if err != nil {
		windows.CloseHandle(handle)
		track_close(w, uintptr(handle))
	}

	event := windows.CreateEventW(nil, true, false, nil)
	if event == nil do return .Backend_Init_Failed
	track_open(w, uintptr(event))
	defer if err != nil {
		windows.CloseHandle(event)
		track_close(w, uintptr(event))
	}

	iocp := windows.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil do return .Backend_Init_Failed
	track_open(w, uintptr(iocp))

	w.overlapped = windows.OVERLAPPED{hEvent=event}
	w.buf        = make([]u8, 8192, w.allocator)
	w.handle     = handle
	w.event      = event
	w.iocp       = iocp

	windows.ReadDirectoryChangesW(handle, raw_data(w.buf), windows.DWORD(len(w.buf)), true, NOTIFY_FILTER, nil, &w.overlapped, nil)

	return .None
}

backend_rec_destroy :: proc (w: ^Watcher_Recursive) {
	if w.iocp != nil {
		windows.CloseHandle(w.iocp)
		track_close(w, uintptr(w.iocp))
	}
	if w.event != nil {
		windows.CloseHandle(w.event)
		track_close(w, uintptr(w.event))
	}
	if w.handle != nil {
		windows.CloseHandle(w.handle)
		track_close(w, uintptr(w.handle))
	}
	if w.buf != nil {
		delete(w.buf, w.allocator)
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
	iocp_drain(w, allocator, out)
}

// === Shared IOCP read helpers ===

iocp_drain :: proc (w: ^$W, allocator: mem.Allocator, out: ^[dynamic]Event)
	where W == Watcher_File || W == Watcher_Dir || W == Watcher_Recursive
{
	for {
		bytes:          windows.DWORD
		key:            windows.ULONG_PTR
		overlapped_out: ^windows.OVERLAPPED

		windows.GetQueuedCompletionStatus(w.iocp, &bytes, &key, &overlapped_out, 50)
		if overlapped_out == nil do break

		if bytes > 0 {
			entry := (^windows.FILE_NOTIFY_INFORMATION)(&w.buf[0])
			for {
				name := fni_name(entry)
				kind := action_normalize(entry.action)

				e: Event
				matched: bool
				when W == Watcher_File {
					if name == w.target {
						e = {kind = kind, path = strings.clone(w.path, allocator)}
						matched = true
					}
				} else {
					fullpath, _ := filepath.join({w.path, name}, allocator)
					e = {
						kind   = kind,
						path   = fullpath,
						is_dir = entry.action == 3 || entry.action == 4,
					}
					matched = true
				}

				if matched {
					append(out, e)
				}
				if entry.next_entry_offset == 0 do break

				entry = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(entry) + uintptr(entry.next_entry_offset))
			}
		}

		windows.ResetEvent(w.event)
		windows.ReadDirectoryChangesW(w.handle, raw_data(w.buf), windows.DWORD(len(w.buf)), false, NOTIFY_FILTER, nil, &w.overlapped, nil)
	}
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
	slice    := name_u16[:name_len]
	buf      := make([]u8, name_len*4, context.temp_allocator)
	str      := windows.utf16_to_utf8_buf(buf, slice)

	return strings.clone(str, context.temp_allocator)
}
