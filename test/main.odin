package test_fsw

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "../fsw"

// === Event collector ===

Collected_Event :: struct {
	kind: fsw.Event_Kind,
	path: string,
}

Collector :: struct {
	mu:     sync.Mutex,
	events: [dynamic]Collected_Event,
}

collector_init :: proc(c: ^Collector) {
	c.events = make([dynamic]Collected_Event, 0, 64)
}

collector_destroy :: proc(c: ^Collector) {
	for ev in c.events {
		delete(ev.path)
	}
	delete(c.events)
}

collector_cb :: proc(event: ^fsw.Event) {
	if _collector == nil { return }
	sync.mutex_lock(&_collector.mu)
	path_copy := strings.clone(event.path)
	append(&_collector.events, Collected_Event{event.kind, path_copy})
	sync.mutex_unlock(&_collector.mu)
}

collector_clear :: proc(c: ^Collector) {
	sync.mutex_lock(&c.mu)
	for ev in c.events {
		delete(ev.path)
	}
	clear(&c.events)
	sync.mutex_unlock(&c.mu)
}

collector_wait :: proc(c: ^Collector, min_count: int, timeout: time.Duration) -> bool {
	deadline := time.time_to_unix(time.now()) + i64(timeout / time.Second) + 1
	for time.time_to_unix(time.now()) < deadline {
		sync.mutex_lock(&c.mu)
		n := len(c.events)
		sync.mutex_unlock(&c.mu)
		if n >= min_count {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

collector_has_kind_path :: proc(c: ^Collector, kind: fsw.Event_Kind, path_substr: string) -> bool {
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for ev in c.events {
		if ev.kind == kind && strings.contains(ev.path, path_substr) {
			return true
		}
	}
	return false
}

collector_count_kind :: proc(c: ^Collector, kind: fsw.Event_Kind) -> int {
	count := 0
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	for ev in c.events {
		if ev.kind == kind {
			count += 1
		}
	}
	return count
}

// Global collector pointer (test funcs set this before creating watchers)
_collector: ^Collector

// Overflow tracking globals (used by test_overflow_tracking)
_overflow_received: bool
_overflow_mu: sync.Mutex

// === Test helpers ===

join_path :: proc(a: string, b: string) -> string {
	s, _ := filepath.join({a, b})
	return s
}

make_temp_dir :: proc(prefix: string) -> (string, bool) {
	name := fmt.tprintf("fsw_test_{}_{}", prefix, time.time_to_unix(time.now()))
	dir := join_path("/tmp", name)
	err := os.mkdir(dir)
	if err != nil {
		return "", false
	}
	return dir, true
}

remove_all :: proc(dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for entry in entries {
		if entry.name == "." || entry.name == ".." { continue }
		full := join_path(dir, entry.name)
		if entry.type == .Directory {
			remove_all(full)
		} else {
			os.remove(full)
		}
	}
	os.remove(dir)
}

write_file :: proc(path: string, content: string) {
	fd, err := os.create(path)
	if err != nil { return }
	os.write(fd, transmute([]byte)content)
	os.close(fd)
}

touch_file :: proc(path: string) {
	write_file(path, "hello")
}

test_pass :: proc(name: string) {
	fmt.printf("  PASS: %s\n", name)
}

test_fail :: proc(name: string, msg: string) {
	fmt.printf("  FAIL: %s — %s\n", name, msg)
}

// === Tests ===

test_poll_file_watcher :: proc() {
	fmt.println("[test] polling file watcher")

	dir, ok := make_temp_dir("poll_file")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	filepath_a := join_path(dir, "a.txt")
	touch_file(filepath_a)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	// Allow watcher to take initial snapshot
	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Modify file
	write_file(filepath_a, "modified content")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "a.txt") {
			test_pass("modify detected")
		} else {
			test_fail("modify detected", "no Modified event")
		}
	} else {
		test_fail("modify detected", "timeout")
	}
	collector_clear(&c)

	// 2. Delete file
	os.remove(filepath_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "a.txt") {
			test_pass("delete detected")
		} else {
			test_fail("delete detected", "no Removed event")
		}
	} else {
		test_fail("delete detected", "timeout")
	}
}

test_poll_dir_watcher :: proc() {
	fmt.println("[test] polling dir watcher")

	dir, ok := make_temp_dir("poll_dir")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_poll(dir, collector_cb, 50 * time.Millisecond)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Create file
	file_a := join_path(dir, "new.txt")
	touch_file(file_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "new.txt") {
			test_pass("file create detected")
		} else {
			test_fail("file create detected", "no Added event")
		}
	} else {
		test_fail("file create detected", "timeout")
	}
	collector_clear(&c)

	// 2. Modify file
	write_file(file_a, "changed")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "new.txt") {
			test_pass("file modify detected")
		} else {
			test_fail("file modify detected", "no Modified event")
		}
	} else {
		test_fail("file modify detected", "timeout")
	}
	collector_clear(&c)

	// 3. Delete file
	os.remove(file_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "new.txt") {
			test_pass("file delete detected")
		} else {
			test_fail("file delete detected", "no Removed event")
		}
	} else {
		test_fail("file delete detected", "timeout")
	}
}

test_poll_recursive_watcher :: proc() {
	fmt.println("[test] polling recursive watcher")

	dir, ok := make_temp_dir("poll_rec")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_poll_recursive(dir, collector_cb, 50 * time.Millisecond)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Create subdir + file in subdir
	subdir := join_path(dir, "sub")
	os.mkdir(subdir)
	time.sleep(100 * time.Millisecond)

	nested_file := join_path(subdir, "deep.txt")
	touch_file(nested_file)

	if collector_wait(&c, 2, 3 * time.Second) {
		if collector_has_kind_path(&c, .Added, "sub") {
			test_pass("subdir create detected")
		} else {
			test_fail("subdir create detected", "no Added event for sub")
		}
		if collector_has_kind_path(&c, .Added, "deep.txt") {
			test_pass("nested file create detected")
		} else {
			test_fail("nested file create detected", "no Added event for deep.txt")
		}
	} else {
		test_fail("recursive create", fmt.tprintf("timeout, got %d events", len(c.events)))
	}
	collector_clear(&c)

	// 2. Modify nested file
	write_file(nested_file, "updated deep content")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "deep.txt") {
			test_pass("nested file modify detected")
		} else {
			test_fail("nested file modify detected", "no Modified event")
		}
	} else {
		test_fail("nested file modify", "timeout")
	}
	collector_clear(&c)

	// 3. Delete nested file
	os.remove(nested_file)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "deep.txt") {
			test_pass("nested file delete detected")
		} else {
			test_fail("nested file delete detected", "no Removed event")
		}
	} else {
		test_fail("nested file delete", "timeout")
	}
}

test_inotify_file_watcher :: proc() {
	fmt.println("[test] inotify file watcher")

	dir, ok := make_temp_dir("inotify_file")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	filepath_a := join_path(dir, "a.txt")
	touch_file(filepath_a)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file(filepath_a, collector_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Modify file
	write_file(filepath_a, "modified inotify")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "a.txt") {
			test_pass("modify detected")
		} else {
			test_fail("modify detected", fmt.tprintf("got events but no Modified"))
		}
	} else {
		test_fail("modify detected", "timeout")
	}
	collector_clear(&c)

	// 2. Delete file
	os.remove(filepath_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "a.txt") {
			test_pass("delete detected")
		} else {
			test_fail("delete detected", fmt.tprintf("got events but no Removed"))
		}
	} else {
		test_fail("delete detected", "timeout")
	}
}

test_inotify_dir_watcher :: proc() {
	fmt.println("[test] inotify dir watcher")

	dir, ok := make_temp_dir("inotify_dir")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir(dir, collector_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Create file
	file_a := join_path(dir, "test.txt")
	touch_file(file_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "test.txt") {
			test_pass("file create detected")
		} else {
			test_fail("file create detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("file create detected", "timeout")
	}
	collector_clear(&c)

	// 2. Delete file
	os.remove(file_a)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "test.txt") {
			test_pass("file delete detected")
		} else {
			test_fail("file delete detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("file delete detected", "timeout")
	}
}

test_inotify_recursive_watcher :: proc() {
	fmt.println("[test] inotify recursive watcher")

	dir, ok := make_temp_dir("inotify_rec")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_recursive(dir, collector_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Create subdir
	subdir := join_path(dir, "sub")
	os.mkdir(subdir)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "sub") {
			test_pass("subdir create detected")
		} else {
			test_fail("subdir create detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("subdir create detected", "timeout")
	}
	collector_clear(&c)

	// 2. Create file in subdir (auto-watched by recursive)
	nested := join_path(subdir, "nested.txt")
	touch_file(nested)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "nested.txt") {
			test_pass("nested file create detected")
		} else {
			test_fail("nested file create detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("nested file create", "timeout")
	}
	collector_clear(&c)

	// 3. Modify nested file
	write_file(nested, "updated")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "nested.txt") {
			test_pass("nested file modify detected")
		} else {
			test_fail("nested file modify detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("nested file modify", "timeout")
	}
	collector_clear(&c)

	// 4. Delete nested file
	os.remove(nested)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "nested.txt") {
			test_pass("nested file delete detected")
		} else {
			test_fail("nested file delete detected", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("nested file delete", "timeout")
	}
}

test_glob_watcher :: proc() {
	fmt.println("[test] glob watcher")

	dir, ok := make_temp_dir("glob")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	// Create a file that matches *.txt BEFORE watcher starts (initial scan)
	pre_existing := join_path(dir, "pre.txt")
	write_file(pre_existing, "existing")

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	pattern := join_path(dir, "*.txt")
	w, err := fsw.watch_glob(pattern, collector_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(200 * time.Millisecond)
	collector_clear(&c)

	// 1. Create a new .txt file (should match)
	new_txt := join_path(dir, "new.txt")
	write_file(new_txt, "hello")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "new.txt") {
			test_pass("matching file create detected")
		} else {
			test_fail("matching file create", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("matching file create", "timeout")
	}
	collector_clear(&c)

	// 2. Create a .log file (should NOT match *.txt)
	new_log := join_path(dir, "test.log")
	write_file(new_log, "log data")
	time.sleep(300 * time.Millisecond)
	sync.mutex_lock(&c.mu)
	log_count := 0
	for ev in c.events {
		if strings.contains(ev.path, ".log") {
			log_count += 1
		}
	}
	sync.mutex_unlock(&c.mu)
	if log_count == 0 {
		test_pass("non-matching file ignored")
	} else {
		test_fail("non-matching file ignored", fmt.tprintf("got %d .log events", log_count))
	}
	collector_clear(&c)

	// 3. Modify the .txt file (should match)
	write_file(new_txt, "modified")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "new.txt") {
			test_pass("matching file modify detected")
		} else {
			test_fail("matching file modify", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("matching file modify", "timeout")
	}
	collector_clear(&c)

	// 4. Delete the .txt file (should match)
	os.remove(new_txt)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Removed, "new.txt") {
			test_pass("matching file delete detected")
		} else {
			test_fail("matching file delete", fmt.tprintf("got: %v", c.events))
		}
	} else {
		test_fail("matching file delete", "timeout")
	}
}

test_stress_many_files :: proc() {
	fmt.println("[test] stress: many files rapidly")

	dir, ok := make_temp_dir("stress_many")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir(dir, collector_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// Create 50 files rapidly
	for i in 0..<50 {
		name := fmt.tprintf("stress_{}.txt", i)
		path := join_path(dir, name)
		touch_file(path)
	}

	// Wait for events to arrive
	collector_wait(&c, 10, 5 * time.Second)

	// Verify watcher is still alive — create one more file with a unique name
	probe := join_path(dir, "PROBE_AFTER_STRESS.txt")
	collector_clear(&c)
	touch_file(probe)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "PROBE_AFTER_STRESS") {
			test_pass("watcher alive after stress")
		} else {
			test_fail("watcher alive after stress", "probe not detected")
		}
	} else {
		test_fail("watcher alive after stress", "timeout")
	}
}

test_stress_rapid_lifecycle :: proc() {
	fmt.println("[test] stress: rapid watcher create/destroy")

	dir, ok := make_temp_dir("stress_lifecycle")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	filepath_a := join_path(dir, "lifecycle.txt")
	touch_file(filepath_a)

	// Create and destroy 20 watchers rapidly
	for i in 0..<20 {
		w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
		if err != .None {
			test_fail("rapid lifecycle", fmt.tprintf("iteration %d: error %v", i, err))
			return
		}
		fsw.destroy(w)
	}

	// Final watcher should still work
	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
	if err != .None {
		test_fail("final watcher create", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	write_file(filepath_a, "after rapid lifecycle")
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Modified, "lifecycle.txt") {
			test_pass("watcher works after rapid lifecycle")
		} else {
			test_fail("final modify", "no Modified event")
		}
	} else {
		test_fail("final modify", "timeout")
	}
}

test_overflow_tracking :: proc() {
	fmt.println("[test] overflow event tracking")

	dir, ok := make_temp_dir("overflow")
	if !ok { test_fail("setup", "cannot create temp dir"); return }
	defer remove_all(dir)

	overflow_cb :: proc(event: ^fsw.Event) {
		if event.kind == .Overflow {
			sync.mutex_lock(&_overflow_mu)
			_overflow_received = true
			sync.mutex_unlock(&_overflow_mu)
		}
		collector_cb(event)
	}

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir(dir, overflow_cb)
	if err != .None {
		test_fail("create watcher", fmt.tprintf("error: %v", err))
		return
	}
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// Create many files rapidly to try to trigger overflow
	// (may not actually overflow on modern kernels with large buffers)
	for i in 0..<200 {
		name := fmt.tprintf("ovf_{}.txt", i)
		path := join_path(dir, name)
		touch_file(path)
	}

	collector_wait(&c, 50, 5 * time.Second)

	sync.mutex_lock(&_overflow_mu)
	had_overflow := _overflow_received
	sync.mutex_unlock(&_overflow_mu)

	if had_overflow {
		test_pass("overflow event delivered")
	} else {
		// Not a failure — kernel buffer may be large enough
		fmt.println("  INFO: no overflow occurred (kernel buffer sufficient)")
		test_pass("overflow tracking (no overflow triggered)")
	}

	// Verify watcher still works after the burst
	probe := join_path(dir, "PROBE_OVERFLOW.txt")
	collector_clear(&c)
	touch_file(probe)
	if collector_wait(&c, 1, 2 * time.Second) {
		if collector_has_kind_path(&c, .Added, "PROBE_OVERFLOW") {
			test_pass("watcher functional after burst")
		} else {
			test_fail("post-burst probe", "not detected")
		}
	} else {
		test_fail("post-burst probe", "timeout")
	}
}

// === Main ===

main :: proc() {
	fmt.println("=== odin-fsw integration tests ===")
	fmt.println()

	test_poll_file_watcher()
	test_poll_dir_watcher()
	test_poll_recursive_watcher()
	test_inotify_file_watcher()
	test_inotify_dir_watcher()
	test_inotify_recursive_watcher()
	test_glob_watcher()
	test_stress_many_files()
	test_stress_rapid_lifecycle()
	test_overflow_tracking()

	fmt.println()
	fmt.println("=== tests complete ===")
}
