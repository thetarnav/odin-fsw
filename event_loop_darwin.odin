// event_loop_darwin.odin — Shared kqueue event loop for macOS.
//
// A single kqueue fd multiplexes multiple watcher fds on one background thread.
// Watchers register their file descriptor(s) with the loop via loop_add_watcher.
// The loop thread calls kevent and dispatches VNode events to the appropriate
// watcher type.
//
// Thread lifecycle: the thread starts on the first loop_add_watcher call and
// self-terminates when the last watcher is removed. A new thread is spawned
// if a watcher is later added to an idle loop.
//
// Thread safety: the mutex is held during dispatch AND during add/remove.
// Callbacks must not call destroy (would deadlock).

package fsw

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/kqueue"
import "core:sys/posix"
import "core:thread"

Event_Loop :: struct {
	kqfd:     posix.FD,
	mu:       sync.Mutex,
	watchers: map[posix.FD]Loop_Watcher,
	thread:   ^thread.Thread,
	running:  bool,
}

_global_loop: ^Event_Loop

_loop_mu: sync.Mutex

get_loop :: proc() -> ^Event_Loop {
	if _global_loop != nil { return _global_loop }
	sync.mutex_lock(&_loop_mu)
	defer sync.mutex_unlock(&_loop_mu)
	if _global_loop != nil { return _global_loop }
	kq, errno := kqueue.kqueue()
	if errno != .NONE { return nil }
	loop := new(Event_Loop, context.allocator)
	if loop == nil { posix.close(kq); return nil }
	loop^ = {
		kqfd     = kq,
		watchers = make(map[posix.FD]Loop_Watcher, context.allocator),
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
	posix.close(loop.kqfd)
	delete(loop.watchers)
	free(loop)
}

@(private)
kq_register :: proc(kq: posix.FD, fd: int) {
	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	kqueue.kevent(kq, []kqueue.KEvent{ev}, nil, nil)
}

loop_add_watcher :: proc(loop: ^Event_Loop, fd: int, w: Loop_Watcher) {
	sync.mutex_lock(&loop.mu)
	kq_register(loop.kqfd, fd)
	loop.watchers[posix.FD(fd)] = w

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
		t := thread.create(kq_event_loop_thread)
		t.data = rawptr(loop)
		thread.start(t)
		loop.thread = t
	}

	sync.mutex_unlock(&loop.mu)
}

loop_add_rec_watcher :: proc(loop: ^Event_Loop, w: ^Watcher_Recursive) {
	sync.mutex_lock(&loop.mu)
	for fd_key in w.watches {
		kq_register(loop.kqfd, fd_key)
		loop.watchers[posix.FD(fd_key)] = Loop_Watcher(w)
	}

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
		t := thread.create(kq_event_loop_thread)
		t.data = rawptr(loop)
		thread.start(t)
		loop.thread = t
	}

	sync.mutex_unlock(&loop.mu)
}

loop_remove_watcher :: proc(loop: ^Event_Loop, fd: int) -> bool {
	sync.mutex_lock(&loop.mu)
	defer sync.mutex_unlock(&loop.mu)

	kevent_del := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Delete},
	}
	kqueue.kevent(loop.kqfd, []kqueue.KEvent{kevent_del}, nil, nil)
	delete_key(&loop.watchers, posix.FD(fd))

	if len(loop.watchers) == 0 {
		loop.running = false
		return true
	}
	return false
}

loop_remove_rec_watcher :: proc(loop: ^Event_Loop, w: ^Watcher_Recursive) -> bool {
	sync.mutex_lock(&loop.mu)
	defer sync.mutex_unlock(&loop.mu)

	for fd_key in w.watches {
		kevent_del := kqueue.KEvent{
			ident  = uintptr(fd_key),
			filter = .VNode,
			flags  = {.Delete},
		}
		kqueue.kevent(loop.kqfd, []kqueue.KEvent{kevent_del}, nil, nil)
		delete_key(&loop.watchers, posix.FD(fd_key))
	}

	if len(loop.watchers) == 0 {
		loop.running = false
		return true
	}
	return false
}

kq_event_loop_thread :: proc(t: ^thread.Thread) {
	loop := (^Event_Loop)(t.data)
	events: [64]kqueue.KEvent

	for {
		timeout := posix.timespec{tv_sec = 0, tv_nsec = 100_000_000}
		n, _ := kqueue.kevent(loop.kqfd, nil, events[:], &timeout)

		sync.mutex_lock(&loop.mu)
		if !loop.running {
			sync.mutex_unlock(&loop.mu)
			break
		}

		// Dispatch file watchers directly from kevent ident.
		if n > 0 {
			for i in 0..<int(n) {
				key := posix.FD(int(events[i].ident))
				w := loop.watchers[key]
			#partial switch ref in w {
			case ^Watcher_File:
				if ref.running && events[i].filter == .VNode {
					fflags := events[i].fflags.vnode
					if fflags == {} { continue }
					e := Event{kind = kq_normalize(fflags), path = ref.path}
					invoke_callback_file(ref, &e)
				}
			}
			}
		}

		// Poll dir watchers for snapshot diffs (kqueue VNode doesn't catch
		// file content changes inside directories).
		for _, w in loop.watchers {
			#partial switch ref in w {
			case ^Watcher_Dir:
				if ref.running {
					kq_dispatch_dir(ref)
				}
			case ^Watcher_Recursive:
				if ref.running {
					kq_dispatch_rec(ref)
				}
			}
		}

		sync.mutex_unlock(&loop.mu)
	}

	sync.mutex_lock(&loop.mu)
	loop.thread = nil
	sync.mutex_unlock(&loop.mu)
}

kq_dispatch_dir :: proc(w: ^Watcher_Dir) {
	current := make(map[string]File_Info, context.temp_allocator)
	snapshot_dir_by_name(w.path, &current)

	for name in w.prev {
		if _, ok := current[name]; !ok {
			e := Event{kind = .Removed, path = name}
			invoke_callback_dir(w, &e)
		}
	}

	for name, fi in current {
		prev, ok := w.prev[name]
		if !ok {
			e := Event{kind = .Added, path = name, is_dir = fi.is_dir}
			invoke_callback_dir(w, &e)
		} else if fi.mtime != prev.mtime || fi.size != prev.size {
			e := Event{kind = .Modified, path = name, is_dir = fi.is_dir}
			invoke_callback_dir(w, &e)
		}
	}

	delete(w.prev)
	w.prev = current
}

kq_dispatch_rec :: proc(w: ^Watcher_Recursive) {
	gw := (^Watcher_Glob)(w.user_data)

	for _, dir_path in w.watches {
		dir_prev, has_prev := w.prev[dir_path]

		current := make(map[string]File_Info, context.temp_allocator)
		snapshot_dir_by_name(dir_path, &current)

		if has_prev {
			for name in dir_prev {
				if _, ok := current[name]; !ok {
					fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
					if join_err != nil { continue }
					e := Event{kind = .Removed, path = fullpath}
					if gw != nil {
						glob_filter_event(gw, &e)
					} else {
						invoke_callback_rec(w, &e)
					}
				}
			}

			for name, fi in current {
				prev_fi, ok := dir_prev[name]
				if !ok {
					fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
					if join_err != nil { continue }
					if fi.is_dir {
						kq_rec_add_watch(w, fullpath)
					}
					e := Event{kind = .Added, path = fullpath, is_dir = fi.is_dir}
					if gw != nil {
						glob_filter_event(gw, &e)
					} else {
						invoke_callback_rec(w, &e)
					}
				} else if fi.mtime != prev_fi.mtime || fi.size != prev_fi.size {
					fullpath, join_err := filepath.join({dir_path, name}, context.temp_allocator)
					if join_err != nil { continue }
					e := Event{kind = .Modified, path = fullpath, is_dir = fi.is_dir}
					if gw != nil {
						glob_filter_event(gw, &e)
					} else {
						invoke_callback_rec(w, &e)
					}
				}
			}

			delete(dir_prev)
		}

		w.prev[dir_path] = current
	}
}

kq_rec_add_watch :: proc(w: ^Watcher_Recursive, dir: string) {
	file, err := os.open(dir, os.O_RDONLY)
	if err != nil { return }
	fd := int(os.fd(file))

	ev := kqueue.KEvent{
		ident  = uintptr(fd),
		filter = .VNode,
		flags  = {.Add, .Clear},
	}
	ev.fflags.vnode = {.Delete, .Write, .Extend, .Attrib, .Link, .Rename}
	loop := get_loop()
	_, errno := kqueue.kevent(loop.kqfd, []kqueue.KEvent{ev}, nil, nil)
	if errno != .NONE {
		os.close(file)
		return
	}

	w.watches[fd] = strings.clone(dir, w.allocator)

	dir_prev := make(map[string]File_Info, w.allocator)
	snapshot_dir_by_name(dir, &dir_prev)
	w.prev[dir] = dir_prev

	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil { return }
	for entry in entries {
		if entry.name == "." || entry.name == ".." { continue }
		if entry.type == .Directory {
			subdir, join_err := filepath.join({dir, entry.name}, context.temp_allocator)
			if join_err != nil { continue }
			kq_rec_add_watch(w, subdir)
		}
	}
}
