package fsw

// Windows backend — ReadDirectoryChangesW + IOCP for all watcher types.
// File watcher watches parent directory and filters by filename.
// Recursive watcher uses bWatchSubtree=TRUE.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"
import "core:thread"

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
action_normalize :: proc(action: DWORD) -> Event_Kind {
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
	return strings.clone_from_string(s, context.temp_allocator)
}

// === Watcher_File ===

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	dir := filepath.dir(w.path)

	wpath := windows.utf8_to_utf16_alloc(dir, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		raw_data(wpath),
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
	success := windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

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
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[0])) // event
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[1])) // iocp
		free((^windows.OVERLAPPED)(w.thread.user_args[4]), w.allocator)
		thread.destroy(w.thread)
	}
	windows.CloseHandle(windows.HANDLE(w.native_handle))
}

win_file_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_File)(t.data)
	handle := windows.HANDLE(w.native_handle)
	event := windows.HANDLE(t.user_args[0])
	iocp := windows.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^windows.OVERLAPPED)(t.user_args[4])
	_, target := filepath.dir(w.path), filepath.base(w.path)

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		ok := windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^windows.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				if name == target {
					kind := action_normalize(entry.action)
					e := Event{kind = kind, path = w.path}
					w.callback(&e)
				}
				if entry.next_entry_offset == 0 { break }
				entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

// === Watcher_Dir ===

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	wpath := windows.utf8_to_utf16_alloc(w.path, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		raw_data(wpath),
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
	windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)

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
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[0]))
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[1]))
		free((^windows.OVERLAPPED)(w.thread.user_args[4]), w.allocator)
		thread.destroy(w.thread)
	}
	windows.CloseHandle(windows.HANDLE(w.native_handle))
}

win_dir_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Dir)(t.data)
	handle := windows.HANDLE(w.native_handle)
	event := windows.HANDLE(t.user_args[0])
	iocp := windows.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^windows.OVERLAPPED)(t.user_args[4])

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		ok := windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^windows.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				kind := action_normalize(entry.action)
				fullpath := w.path
				if name != "" {
				joined, _ := filepath.join({w.path, name}, context.temp_allocator)
				fullpath = joined
			}
			e := Event{kind = kind, path = fullpath}
			w.callback(&e)
				if entry.next_entry_offset == 0 { break }
				entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), false, NOTIFY_FILTER, nil, overlapped, nil)
	}
}

// === Watcher_Recursive ===

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	wpath := windows.utf8_to_utf16_alloc(w.path, context.temp_allocator)
	if len(wpath) == 0 { return .Backend_Init_Failed }

	handle := windows.CreateFileW(
		raw_data(wpath),
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
	windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)

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
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[0]))
		windows.CloseHandle(windows.HANDLE(w.thread.user_args[1]))
		free((^windows.OVERLAPPED)(w.thread.user_args[4]), w.allocator)
		thread.destroy(w.thread)
	}
	windows.CloseHandle(windows.HANDLE(w.native_handle))
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	// Windows ReadDirectoryChangesW with bWatchSubtree=TRUE
	// automatically tracks new/deleted subdirectories.
	// No manual rescan needed.
	return .None
}

win_rec_thread :: proc(t: ^thread.Thread) {
	w := (^Watcher_Recursive)(t.data)
	handle := windows.HANDLE(w.native_handle)
	event := windows.HANDLE(t.user_args[0])
	iocp := windows.HANDLE(t.user_args[1])
	buf := ([^]u8)(t.user_args[2])[:int(uintptr(t.user_args[3]))]
	overlapped := (^windows.OVERLAPPED)(t.user_args[4])
	gw := (^Watcher_Glob)(w.user_data)

	for w.running {
		bytes: DWORD = 0
		key: ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		ok := windows.GetQueuedCompletionStatus(iocp, &bytes, &key, &overlapped_out, 50)
		if ok != 0 && bytes > 0 {
			entry := cast(^windows.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
			for {
				name := fni_name(entry)
				kind := action_normalize(entry.action)
				fullpath := w.path
				if name != "" {
				joined, _ := filepath.join({w.path, name}, context.temp_allocator)
				fullpath = joined
			}
			e := Event{kind = kind, path = fullpath}
			if gw != nil {
					glob_filter_event(gw, &e)
				} else {
					w.callback(&e)
				}
				if entry.next_entry_offset == 0 { break }
				entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
			}
		}
		windows.ResetEvent(event)
		windows.ReadDirectoryChangesW(handle, raw_data(buf), DWORD(len(buf)), true, NOTIFY_FILTER, nil, overlapped, nil)
	}
}
