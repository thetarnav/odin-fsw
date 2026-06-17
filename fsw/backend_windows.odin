package fsw

// Windows backend — ReadDirectoryChangesW + IOCP for all watcher types.
// File watcher watches parent directory and filters by filename.
// Recursive watcher uses bWatchSubtree=TRUE.

import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"
import "core:thread"

@(private)
NOTIFY_FILTER :: win32.FILE_NOTIFY_CHANGE_FILE_NAME | win32.FILE_NOTIFY_CHANGE_DIR_NAME | win32.FILE_NOTIFY_CHANGE_SIZE | win32.FILE_NOTIFY_CHANGE_LAST_WRITE | win32.FILE_NOTIFY_CHANGE_ATTRIBUTES | win32.FILE_NOTIFY_CHANGE_CREATION

@(private)
action_normalize :: proc(action: DWORD) -> Event_Kind {
	switch action {
	case win32.FILE_ACTION_ADDED:            return .Added
	case win32.FILE_ACTION_REMOVED:          return .Removed
	case win32.FILE_ACTION_MODIFIED:         return .Modified
	case win32.FILE_ACTION_RENAMED_OLD_NAME: return .Renamed
	case win32.FILE_ACTION_RENAMED_NEW_NAME: return .Renamed
	case:                                    return .Modified
	}
}

@(private)
fni_name :: proc(entry: ^win32.FILE_NOTIFY_INFORMATION) -> string {
	if entry.file_name_length == 0 { return "" }
	name_ptr := rawptr(&entry.file_name[0])
	name_u16 := cast([^]u16) name_ptr
	name_len := int(entry.file_name_length) / 2
	slice := name_u16[:name_len]
	buf := make([]u8, len(slice)*4, context.temp_allocator)
	s := win32.utf16_to_utf8_buf(buf, slice)
	return strings.clone_from_string(s, context.allocator)
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	dir := filepath.dir(w.path)

	wpath := win32.utf8_to_utf16_alloc(dir, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := win32.CreateFileW(
		raw_data(wpath),
		win32.FILE_LIST_DIRECTORY,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := win32.CreateEventW(nil, true, false, nil)
	if event == nil {
		win32.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(win32.OVERLAPPED, context.allocator)
	overlapped.hEvent = event

	iocp := win32.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		win32.CloseHandle(event)
		win32.CloseHandle(handle)
		free(overlapped, context.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 4096, w.allocator)
	success := win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	w.native_handle = int(uintptr(handle))
	t := thread.create(win_file_thread)
	t.data = rawptr(w)
	t.user_args[0] = rawptr(event)
	t.user_args[1] = rawptr(iocp)
	t.user_args[2] = rawptr(raw_data(buf))
	t.user_args[3] = rawptr(uintptr(len(buf)))
	t.user_args[4] = rawptr(overlapped)
	thread.start(t)
	w.thread = t
	_ = success
	return .None
}

backend_file_destroy :: proc(w: ^Watcher_File) {
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[0])) // event
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[1])) // iocp
		free((^win32.OVERLAPPED)(w.thread.user_args[4]), context.allocator)
		thread.destroy(w.thread)
	}
	win32.CloseHandle(win32.HANDLE(w.native_handle))
}

win_file_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_File)(t.data)
	handle := win32.HANDLE(w.native_handle)
	event := win32.HANDLE(t.user_args[0])
	iocp := win32.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^win32.OVERLAPPED)(t.user_args[4])
	_, target := filepath.dir(w.path), filepath.base(w.path)

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^win32.OVERLAPPED = nil
		ok := win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^win32.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				if name == target {
					kind := action_normalize(entry.action)
					e := Event{kind = kind, path = w.path}
					w.callback(&e)
				}
				if entry.next_entry_offset == 0 { break }
				entry = cast(^win32.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		win32.ResetEvent(event)
		win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	wpath := win32.utf8_to_utf16_alloc(w.path, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := win32.CreateFileW(
		raw_data(wpath),
		win32.FILE_LIST_DIRECTORY,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := win32.CreateEventW(nil, true, false, nil)
	if event == nil {
		win32.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(win32.OVERLAPPED, context.allocator)
	overlapped.hEvent = event

	iocp := win32.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		win32.CloseHandle(event)
		win32.CloseHandle(handle)
		free(overlapped, context.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 4096, w.allocator)
	win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

	w.native_handle = int(uintptr(handle))
	t := thread.create(win_dir_thread)
	t.data = rawptr(w)
	t.user_args[0] = rawptr(event)
	t.user_args[1] = rawptr(iocp)
	t.user_args[2] = rawptr(raw_data(buf))
	t.user_args[3] = rawptr(uintptr(len(buf)))
	t.user_args[4] = rawptr(overlapped)
	thread.start(t)
	w.thread = t
	return .None
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[0]))
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[1]))
		free((^win32.OVERLAPPED)(w.thread.user_args[4]), context.allocator)
		thread.destroy(w.thread)
	}
	win32.CloseHandle(win32.HANDLE(w.native_handle))
}

win_dir_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Dir)(t.data)
	handle := win32.HANDLE(w.native_handle)
	event := win32.HANDLE(t.user_args[0])
	iocp := win32.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^win32.OVERLAPPED)(t.user_args[4])

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^win32.OVERLAPPED = nil
		ok := win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^win32.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				kind := action_normalize(entry.action)
				fullpath := w.path
				if name != "" {
					joined, _ := filepath.join({w.path, name})
					fullpath = joined
				}
				e := Event{kind = kind, path = fullpath}
				w.callback(&e)
				if entry.next_entry_offset == 0 { break }
				entry = cast(^win32.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		win32.ResetEvent(event)
		win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	wpath := win32.utf8_to_utf16_alloc(w.path, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := win32.CreateFileW(
		raw_data(wpath),
		win32.FILE_LIST_DIRECTORY,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE { return .Backend_Init_Failed }

	event := win32.CreateEventW(nil, true, false, nil)
	if event == nil {
		win32.CloseHandle(handle)
		return .Backend_Init_Failed
	}
	overlapped := new(win32.OVERLAPPED, context.allocator)
	overlapped.hEvent = event

	iocp := win32.CreateIoCompletionPort(handle, nil, 0, 1)
	if iocp == nil {
		win32.CloseHandle(event)
		win32.CloseHandle(handle)
		free(overlapped, context.allocator)
		return .Backend_Init_Failed
	}

	buf := make([]u8, 8192, w.allocator)
	win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)

	w.native_handle = int(uintptr(handle))
	t := thread.create(win_rec_thread)
	t.data = rawptr(w)
	t.user_args[0] = rawptr(event)
	t.user_args[1] = rawptr(iocp)
	t.user_args[2] = rawptr(raw_data(buf))
	t.user_args[3] = rawptr(uintptr(len(buf)))
	t.user_args[4] = rawptr(overlapped)
	thread.start(t)
	w.thread = t
	return .None
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
	if w.thread != nil {
		w.running = false
		thread.join(w.thread)
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[0]))
		win32.CloseHandle(win32.HANDLE(w.thread.user_args[1]))
		free((^win32.OVERLAPPED)(w.thread.user_args[4]), context.allocator)
		thread.destroy(w.thread)
	}
	win32.CloseHandle(win32.HANDLE(w.native_handle))
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	// Windows ReadDirectoryChangesW with bWatchSubtree=TRUE
	// automatically tracks new/deleted subdirectories.
	// No manual rescan needed.
	return .None
}

win_rec_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Recursive)(t.data)
	handle := win32.HANDLE(w.native_handle)
	event := win32.HANDLE(t.user_args[0])
	iocp := win32.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^win32.OVERLAPPED)(t.user_args[4])
	gw := (^Watcher_Glob)(w.user_data)

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^win32.OVERLAPPED = nil
		ok := win32.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^win32.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				kind := action_normalize(entry.action)
				fullpath := w.path
				if name != "" {
					joined, _ := filepath.join({w.path, name})
					fullpath = joined
				}
				e := Event{kind = kind, path = fullpath}
				if gw != nil {
					glob_filter_event(gw, &e)
				} else {
					w.callback(&e)
				}
				if entry.next_entry_offset == 0 { break }
				entry = cast(^win32.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		win32.ResetEvent(event)
		win32.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)
	}
}
