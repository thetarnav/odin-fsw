// event_loop_linux.odin — Shared epoll event loop for Linux.
//
// A single epoll fd multiplexes multiple inotify fds on one background thread.
// Watchers register their inotify fd with the loop via loop_add_watcher.
// The loop thread calls epoll_wait and dispatches inotify events to the
// appropriate watcher type.
//
// Thread lifecycle: the thread starts on the first loop_add_watcher call and
// self-terminates when the last watcher is removed. A new thread is spawned
// if a watcher is later added to an idle loop. The old thread is joined
// before a new one is created.
//
// Thread safety: the mutex is held during read+dispatch AND during add/remove.
// Callbacks must not call destroy (would deadlock). This matches the existing
// per-watcher thread limitation documented in the README.

package fsw

import "core:path/filepath"
import "core:sync"
import "core:sys/linux"
import "core:thread"

Event_Loop :: struct {
	epfd:      linux.Fd,
	mu:        sync.Mutex,
	watchers:  map[linux.Fd]Loop_Watcher,
	thread:    ^thread.Thread,
	running:   bool,
}

_global_loop: ^Event_Loop

get_loop :: proc() -> ^Event_Loop {
	if _global_loop != nil { return _global_loop }
	epfd, errno := linux.epoll_create()
	if errno != .NONE { return nil }
	loop := new(Event_Loop, context.allocator)
	if loop == nil { linux.close(epfd); return nil }
	loop^ = {
		epfd     = epfd,
		watchers = make(map[linux.Fd]Loop_Watcher, context.allocator),
	}
	_global_loop = loop
	return loop
}

destroy_loop :: proc() {
	if _global_loop == nil { return }
	loop := _global_loop
	_global_loop = nil
	sync.mutex_lock(&loop.mu)
	loop.running = false
	t := loop.thread
	loop.thread = nil
	sync.mutex_unlock(&loop.mu)
	if t != nil {
		thread.join(t)
		thread.destroy(t)
	}
	linux.close(loop.epfd)
	delete(loop.watchers)
	free(loop)
}

loop_add_watcher :: proc(loop: ^Event_Loop, fd: linux.Fd, w: Loop_Watcher) {
	sync.mutex_lock(&loop.mu)

	ev: linux.EPoll_Event
	ev.events = {.IN}
	ev.data.fd = fd
	linux.epoll_ctl(loop.epfd, .ADD, fd, &ev)
	loop.watchers[fd] = w

	if !loop.running {
		loop.running = true
		// Join old thread if it's still around (self-terminated from previous cycle).
		if loop.thread != nil {
			t := loop.thread
			loop.thread = nil
			sync.mutex_unlock(&loop.mu)
			thread.join(t)
			thread.destroy(t)
			sync.mutex_lock(&loop.mu)
		}
		t := thread.create(epoll_event_loop_thread)
		t.data = rawptr(loop)
		thread.start(t)
		loop.thread = t
	}

	sync.mutex_unlock(&loop.mu)
}

// loop_remove_watcher removes a watcher fd from the loop. Returns true if the
// loop has no remaining watchers (caller should call destroy_loop).
loop_remove_watcher :: proc(loop: ^Event_Loop, fd: linux.Fd) -> bool {
	sync.mutex_lock(&loop.mu)
	defer sync.mutex_unlock(&loop.mu)

	linux.epoll_ctl(loop.epfd, .DEL, fd, nil)
	delete_key(&loop.watchers, fd)
	linux.close(fd)

	// Signal thread to exit when no watchers remain.
	if len(loop.watchers) == 0 {
		loop.running = false
		return true
	}
	return false
}

epoll_event_loop_thread :: proc(t: ^thread.Thread) {
	loop := (^Event_Loop)(t.data)
	events: [16]linux.EPoll_Event
	buf: [8192]byte

	for {
		n, _ := linux.epoll_wait(loop.epfd, ([^]linux.EPoll_Event)(&events[0]), i32(len(events)), 100)
		if !loop.running {
			break
		}
		if n <= 0 {
			continue
		}

		sync.mutex_lock(&loop.mu)
		for i in 0..<n {
			fd := events[i].data.fd
			w, ok := loop.watchers[fd]
			if !ok { continue }
			read_n, read_errno := linux.read(fd, buf[:])
			if read_errno == .EAGAIN || read_n <= 0 { continue }
			switch ref in w {
			case ^Watcher_File:
				if ref.running {
					epoll_dispatch_file(ref, buf[:], read_n)
				}
			case ^Watcher_Dir:
				if ref.running {
					epoll_dispatch_dir(ref, buf[:], read_n)
				}
			case ^Watcher_Recursive:
				if ref.running {
					epoll_dispatch_rec(ref, buf[:], read_n)
				}
			}
		}
		sync.mutex_unlock(&loop.mu)
	}

	// Thread is exiting. Clear its reference so loop_add_watcher can join/destroy it.
	sync.mutex_lock(&loop.mu)
	loop.thread = nil
	sync.mutex_unlock(&loop.mu)
}

epoll_dispatch_file :: proc(w: ^Watcher_File, buf: []byte, n: int) {
	offset := 0
	for offset + size_of(linux.Inotify_Event) <= n {
		event := (^linux.Inotify_Event)(rawptr(&buf[offset]))
		event_size := size_of(linux.Inotify_Event) + int(event.len)
		if offset + event_size > n { break }
		if event.wd == linux.Wd(w.wd) {
			name := inotify_event_name(event)
			kind := inotify_normalize(event.mask)
			path := w.path
			if name != "" {
				path, _ = filepath.join({w.path, name}, context.temp_allocator)
			}
			e := Event{kind = kind, path = path, is_dir = .ISDIR in event.mask}
			invoke_callback_file(w, &e)
		}
		offset += event_size
	}
}

epoll_dispatch_dir :: proc(w: ^Watcher_Dir, buf: []byte, n: int) {
	offset := 0
	for offset + size_of(linux.Inotify_Event) <= n {
		event := (^linux.Inotify_Event)(rawptr(&buf[offset]))
		event_size := size_of(linux.Inotify_Event) + int(event.len)
		if offset + event_size > n { break }
		if event.wd == linux.Wd(w.wd) {
			name := inotify_event_name(event)
			kind := inotify_normalize(event.mask)
			path := w.path
			if name != "" {
				path, _ = filepath.join({w.path, name}, context.temp_allocator)
			}
			e := Event{kind = kind, path = path, is_dir = .ISDIR in event.mask}
			invoke_callback_dir(w, &e)
		}
		offset += event_size
	}
}

epoll_dispatch_rec :: proc(w: ^Watcher_Recursive, buf: []byte, n: int) {
	gw := (^Watcher_Glob)(w.user_data)
	offset := 0
	for offset + size_of(linux.Inotify_Event) <= n {
		event := (^linux.Inotify_Event)(rawptr(&buf[offset]))
		event_size := size_of(linux.Inotify_Event) + int(event.len)
		if offset + event_size > n { break }
		name := inotify_event_name(event)
		dir_path, ok := w.watches[int(event.wd)]
		if ok {
			kind := inotify_normalize(event.mask)
			path := dir_path
			if name != "" {
				path, _ = filepath.join({dir_path, name}, context.temp_allocator)
			}
			is_dir := .ISDIR in event.mask
			if kind == .Added && is_dir {
				rec_add_watch(w, path)
			}
			e := Event{kind = kind, path = path, is_dir = is_dir}
			if gw != nil {
				glob_filter_event(gw, &e)
			} else {
				invoke_callback_rec(w, &e)
			}
		}
		offset += event_size
	}
}
