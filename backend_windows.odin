// backend_windows.odin — Windows backend using ReadDirectoryChangesW + IOCP.
//
// Platform-specific backend compiled only on Windows.
// Uses a shared IOCP event loop (event_loop_windows.odin).
// Implements all backend procs for Watcher_File, Watcher_Dir, and Watcher_Recursive.

package fsw

import "core:path/filepath"
import "core:sys/windows"

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	dir := filepath.dir(w.path)

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

	buf := make([]u8, 4096, w.allocator)

	w.native_handle = int(uintptr(handle))
	w.event = rawptr(event)
	w.overlapped = rawptr(overlapped)
	w.buf_ptr = raw_data(buf)
	w.buf_len = uintptr(len(buf))

	loop := get_loop()
	if loop == nil {
		windows.CloseHandle(event)
		free(overlapped, w.allocator)
		free(raw_data(buf), w.allocator)
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}

	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	loop_add_watcher(loop, handle, overlapped, Loop_Watcher(w))
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, (^windows.OVERLAPPED)(w.overlapped))
	}
	windows.CancelIo(windows.HANDLE(uintptr(w.native_handle)))
	windows.CloseHandle(windows.HANDLE(w.event))
	free((^windows.OVERLAPPED)(w.overlapped), w.allocator)
	free(([^]u8)(w.buf_ptr), w.allocator)
	windows.CloseHandle(windows.HANDLE(uintptr(w.native_handle)))
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

	buf := make([]u8, 4096, w.allocator)

	w.native_handle = int(uintptr(handle))
	w.event = rawptr(event)
	w.overlapped = rawptr(overlapped)
	w.buf_ptr = raw_data(buf)
	w.buf_len = uintptr(len(buf))

	loop := get_loop()
	if loop == nil {
		windows.CloseHandle(event)
		free(overlapped, w.allocator)
		free(raw_data(buf), w.allocator)
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}

	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	loop_add_watcher(loop, handle, overlapped, Loop_Watcher(w))
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, (^windows.OVERLAPPED)(w.overlapped))
	}
	windows.CancelIo(windows.HANDLE(uintptr(w.native_handle)))
	windows.CloseHandle(windows.HANDLE(w.event))
	free((^windows.OVERLAPPED)(w.overlapped), w.allocator)
	free(([^]u8)(w.buf_ptr), w.allocator)
	windows.CloseHandle(windows.HANDLE(uintptr(w.native_handle)))
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

	buf := make([]u8, 8192, w.allocator)

	w.native_handle = int(uintptr(handle))
	w.event = rawptr(event)
	w.overlapped = rawptr(overlapped)
	w.buf_ptr = raw_data(buf)
	w.buf_len = uintptr(len(buf))

	loop := get_loop()
	if loop == nil {
		windows.CloseHandle(event)
		free(overlapped, w.allocator)
		free(raw_data(buf), w.allocator)
		windows.CloseHandle(handle)
		return .Backend_Init_Failed
	}

	windows.ReadDirectoryChangesW(handle, raw_data(buf), windows.DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)

	loop_add_watcher(loop, handle, overlapped, Loop_Watcher(w))
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	loop := get_loop()
	if loop != nil {
		loop_remove_watcher(loop, (^windows.OVERLAPPED)(w.overlapped))
	}
	windows.CancelIo(windows.HANDLE(uintptr(w.native_handle)))
	windows.CloseHandle(windows.HANDLE(w.event))
	free((^windows.OVERLAPPED)(w.overlapped), w.allocator)
	free(([^]u8)(w.buf_ptr), w.allocator)
	windows.CloseHandle(windows.HANDLE(uintptr(w.native_handle)))
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	return .None
}
