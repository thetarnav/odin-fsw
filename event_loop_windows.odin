// event_loop_windows.odin — Shared IOCP event loop for Windows.
//
// A single I/O completion port multiplexes multiple directory watchers on one
// background thread. Each watcher opens a directory handle and associates it
// with the shared IOCP via CreateIoCompletionPort. ReadDirectoryChangesW is
// issued with per-watcher OVERLAPPED + event + buffer.
//
// Thread lifecycle: the thread starts on the first loop_add_watcher call and
// self-terminates when the last watcher is removed. A new thread is spawned
// if a watcher is later added to an idle loop.
//
// Thread safety: the mutex is held during dispatch AND during add/remove.
// Callbacks must not call destroy (would deadlock).

package fsw

import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/windows"
import "core:thread"

Event_Loop :: struct {
	iocp:     windows.HANDLE,
	mu:       sync.Mutex,
	watchers: map[^windows.OVERLAPPED]Loop_Watcher,
	thread:   ^thread.Thread,
	running:  bool,
}

_global_loop: ^Event_Loop

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

_loop_mu: sync.Mutex

get_loop :: proc() -> ^Event_Loop {
	if _global_loop != nil { return _global_loop }
	sync.mutex_lock(&_loop_mu)
	defer sync.mutex_unlock(&_loop_mu)
	if _global_loop != nil { return _global_loop }
	iocp := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, 0, 1)
	if iocp == nil { return nil }
	loop := new(Event_Loop, context.allocator)
	if loop == nil { windows.CloseHandle(iocp); return nil }
	loop^ = {
		iocp     = iocp,
		watchers = make(map[^windows.OVERLAPPED]Loop_Watcher, context.allocator),
	}
	_global_loop = loop
	return loop
}

destroy_loop :: proc() {
	sync.mutex_lock(&_loop_mu)
	if _global_loop == nil {
		sync.mutex_unlock(&_loop_mu)
		return
	}
	loop := _global_loop
	_global_loop = nil
	sync.mutex_unlock(&_loop_mu)
	sync.mutex_lock(&loop.mu)
	loop.running = false
	t := loop.thread
	loop.thread = nil
	sync.mutex_unlock(&loop.mu)
	if t != nil {
		thread.join(t)
		thread.destroy(t)
	}
	windows.CloseHandle(loop.iocp)
	delete(loop.watchers)
	free(loop)
}

loop_add_watcher :: proc(loop: ^Event_Loop, handle: windows.HANDLE, overlapped: ^windows.OVERLAPPED, w: Loop_Watcher) {
	sync.mutex_lock(&loop.mu)

	windows.CreateIoCompletionPort(handle, loop.iocp, 0, 1)
	loop.watchers[overlapped] = w

	if !loop.running {
		loop.running = true
		if loop.thread != nil {
			t := loop.thread
			loop.thread = nil
			sync.mutex_unlock(&loop.mu)
			thread.join(t)
			thread.destroy(t)
			sync.mutex_lock(&loop.mu)
		}
		t := thread.create(iocp_event_loop_thread)
		t.data = rawptr(loop)
		thread.start(t)
		loop.thread = t
	}

	sync.mutex_unlock(&loop.mu)
}

loop_remove_watcher :: proc(loop: ^Event_Loop, overlapped: ^windows.OVERLAPPED) -> bool {
	sync.mutex_lock(&loop.mu)
	defer sync.mutex_unlock(&loop.mu)

	delete_key(&loop.watchers, overlapped)

	if len(loop.watchers) == 0 {
		loop.running = false
		return true
	}
	return false
}

iocp_event_loop_thread :: proc(t: ^thread.Thread) {
	loop := (^Event_Loop)(t.data)

	for {
		bytes: windows.DWORD = 0
		key: windows.ULONG_PTR = 0
		overlapped_out: ^windows.OVERLAPPED = nil
		ok := windows.GetQueuedCompletionStatus(loop.iocp, &bytes, &key, &overlapped_out, 50)

		sync.mutex_lock(&loop.mu)
		if !loop.running {
			sync.mutex_unlock(&loop.mu)
			break
		}

		if bool(ok) && bytes > 0 && overlapped_out != nil {
			w := loop.watchers[overlapped_out]
			#partial switch ref in w {
			case ^Watcher_File:
				if ref.running {
					win_dispatch_file(ref, bytes)
				}
			case ^Watcher_Dir:
				if ref.running {
					win_dispatch_dir(ref, bytes)
				}
			case ^Watcher_Recursive:
				if ref.running {
					win_dispatch_rec(ref, bytes)
				}
			}
		}

		sync.mutex_unlock(&loop.mu)
	}

	sync.mutex_lock(&loop.mu)
	loop.thread = nil
	sync.mutex_unlock(&loop.mu)
}

win_dispatch_file :: proc(w: ^Watcher_File, bytes: windows.DWORD) {
	_, target := filepath.dir(w.path), filepath.base(w.path)
	buf := ([^]u8)(w.buf_ptr)[:int(w.buf_len)]

	entry := cast(^windows.FILE_NOTIFY_INFORMATION) rawptr(&buf[0])
	for {
		name := fni_name(entry)
		if name == target {
			e := Event{kind = action_normalize(entry.action), path = w.path}
			invoke_callback_file(w, &e)
		}
		if entry.next_entry_offset == 0 { break }
		entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
	}

	windows.ResetEvent(windows.HANDLE(w.event))
	windows.ReadDirectoryChangesW(
		windows.HANDLE(uintptr(w.native_handle)),
		raw_data(buf),
		windows.DWORD(len(buf)),
		false,
		NOTIFY_FILTER,
		nil,
		(^windows.OVERLAPPED)(w.overlapped),
		nil,
	)
}

win_dispatch_dir :: proc(w: ^Watcher_Dir, bytes: windows.DWORD) {
	buf := ([^]u8)(w.buf_ptr)[:int(w.buf_len)]

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
		invoke_callback_dir(w, &e)
		if entry.next_entry_offset == 0 { break }
		entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
	}

	windows.ResetEvent(windows.HANDLE(w.event))
	windows.ReadDirectoryChangesW(
		windows.HANDLE(uintptr(w.native_handle)),
		raw_data(buf),
		windows.DWORD(len(buf)),
		false,
		NOTIFY_FILTER,
		nil,
		(^windows.OVERLAPPED)(w.overlapped),
		nil,
	)
}

win_dispatch_rec :: proc(w: ^Watcher_Recursive, bytes: windows.DWORD) {
	gw := (^Watcher_Glob)(w.user_data)
	buf := ([^]u8)(w.buf_ptr)[:int(w.buf_len)]

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
			invoke_callback_rec(w, &e)
		}
		if entry.next_entry_offset == 0 { break }
		entry = cast(^windows.FILE_NOTIFY_INFORMATION)(uintptr(rawptr(entry)) + uintptr(entry.next_entry_offset))
	}

	windows.ResetEvent(windows.HANDLE(w.event))
	windows.ReadDirectoryChangesW(
		windows.HANDLE(uintptr(w.native_handle)),
		raw_data(buf),
		windows.DWORD(len(buf)),
		true,
		NOTIFY_FILTER,
		nil,
		(^windows.OVERLAPPED)(w.overlapped),
		nil,
	)
}
