package test_fsw

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "../fsw"

// === Event collector ===

Collected_Event :: struct {
	kind: fsw.Event_Kind,
	path: string,
}

Collector :: struct {
	mu:        sync.Mutex,
	events:    [dynamic]Collected_Event,
	allocator: mem.Allocator,
}

collector_init :: proc(c: ^Collector, allocator := context.allocator) {
	c.allocator = allocator
	c.events = make([dynamic]Collected_Event, 0, 64, allocator)
}

collector_destroy :: proc(c: ^Collector) {
	for ev in c.events {
		delete(ev.path, c.allocator)
	}
	delete(c.events)
}

collector_cb :: proc(event: ^fsw.Event) {
	if _collector == nil { return }
	sync.mutex_lock(&_collector.mu)
	path_copy := strings.clone(event.path, _collector.allocator)
	append(&_collector.events, Collected_Event{event.kind, path_copy})
	sync.mutex_unlock(&_collector.mu)
}

collector_clear :: proc(c: ^Collector) {
	sync.mutex_lock(&c.mu)
	for ev in c.events {
		delete(ev.path, c.allocator)
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

// === Test helpers ===

join_path :: proc(a: string, b: string) -> string {
	s, _ := filepath.join({a, b}, context.temp_allocator)
	return s
}

make_temp_dir :: proc(t: ^testing.T, prefix: string) -> string {
	name := fmt.tprintf("fsw_test_{}_{}", prefix, time.time_to_unix(time.now()))
	dir := join_path("/tmp", name)
	err := os.mkdir(dir)
	testing.expectf(t, err == nil, "cannot create temp dir %s: %v", dir, err)
	return dir
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

// === Tests ===

@(test)
test_poll_file_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "poll_file")
	defer remove_all(dir)

	filepath_a := join_path(dir, "a.txt")
	touch_file(filepath_a)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
	testing.expectf(t, err == .None, "watch_file_poll error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	// Allow watcher to take initial snapshot
	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Modify file
	write_file(filepath_a, "modified content")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "a.txt"), "modify: no Modified event")
	collector_clear(&c)

	// 2. Delete file
	os.remove(filepath_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "a.txt"), "delete: no Removed event")
}

@(test)
test_poll_dir_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "poll_dir")
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_poll(dir, collector_cb, 50 * time.Millisecond)
	testing.expectf(t, err == .None, "watch_dir_poll error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Create file
	file_a := join_path(dir, "new.txt")
	touch_file(file_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "new.txt"), "create: no Added event")
	collector_clear(&c)

	// 2. Modify file
	write_file(file_a, "changed")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "new.txt"), "modify: no Modified event")
	collector_clear(&c)

	// 3. Delete file
	os.remove(file_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "new.txt"), "delete: no Removed event")
}

@(test)
test_poll_recursive_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "poll_rec")
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_poll_recursive(dir, collector_cb, 50 * time.Millisecond)
	testing.expectf(t, err == .None, "watch_dir_poll_recursive error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	// 1. Create subdir + file in subdir
	subdir := join_path(dir, "sub")
	os.mkdir(subdir)
	time.sleep(100 * time.Millisecond)

	nested_file := join_path(subdir, "deep.txt")
	touch_file(nested_file)

	testing.expect(t, collector_wait(&c, 2, 3 * time.Second), "recursive create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "sub"), "subdir create: no Added event")
	testing.expect(t, collector_has_kind_path(&c, .Added, "deep.txt"), "nested file create: no Added event")
	collector_clear(&c)

	// 2. Modify nested file
	write_file(nested_file, "updated deep content")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "nested modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "deep.txt"), "nested modify: no Modified event")
	collector_clear(&c)

	// 3. Delete nested file
	os.remove(nested_file)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "nested delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "deep.txt"), "nested delete: no Removed event")
}

@(test)
test_inotify_file_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "inotify_file")
	defer remove_all(dir)

	filepath_a := join_path(dir, "a.txt")
	touch_file(filepath_a)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file(filepath_a, collector_cb)
	testing.expectf(t, err == .None, "watch_file error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Modify file
	write_file(filepath_a, "modified inotify")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "a.txt"), "modify: no Modified event")
	collector_clear(&c)

	// 2. Delete file
	os.remove(filepath_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "a.txt"), "delete: no Removed event")
}

@(test)
test_inotify_dir_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "inotify_dir")
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir(dir, collector_cb)
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Create file
	file_a := join_path(dir, "test.txt")
	touch_file(file_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "test.txt"), "create: no Added event")
	collector_clear(&c)

	// 2. Delete file
	os.remove(file_a)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "test.txt"), "delete: no Removed event")
}

@(test)
test_inotify_recursive_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "inotify_rec")
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir_recursive(dir, collector_cb)
	testing.expectf(t, err == .None, "watch_dir_recursive error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// 1. Create subdir
	subdir := join_path(dir, "sub")
	os.mkdir(subdir)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "subdir create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "sub"), "subdir create: no Added event")
	collector_clear(&c)

	// 2. Create file in subdir (auto-watched by recursive)
	nested := join_path(subdir, "nested.txt")
	touch_file(nested)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "nested create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "nested.txt"), "nested create: no Added event")
	collector_clear(&c)

	// 3. Modify nested file
	write_file(nested, "updated")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "nested modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "nested.txt"), "nested modify: no Modified event")
	collector_clear(&c)

	// 4. Delete nested file
	os.remove(nested)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "nested delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "nested.txt"), "nested delete: no Removed event")
}

@(test)
test_glob_watcher :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "glob")
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
	testing.expectf(t, err == .None, "watch_glob error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(200 * time.Millisecond)
	collector_clear(&c)

	// 1. Create a new .txt file (should match)
	new_txt := join_path(dir, "new.txt")
	write_file(new_txt, "hello")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "matching create: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "new.txt"), "matching create: no Added event")
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
	testing.expect_value(t, log_count, 0)
	collector_clear(&c)

	// 3. Modify the .txt file (should match)
	write_file(new_txt, "modified")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "matching modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "new.txt"), "matching modify: no Modified event")
	collector_clear(&c)

	// 4. Delete the .txt file (should match)
	os.remove(new_txt)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "matching delete: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Removed, "new.txt"), "matching delete: no Removed event")
}

@(test)
test_stress_many_files :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "stress_many")
	defer remove_all(dir)

	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_dir(dir, collector_cb)
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil { return }
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
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "post-stress probe: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "PROBE_AFTER_STRESS"), "post-stress probe: not detected")
}

@(test)
test_stress_rapid_lifecycle :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "stress_lifecycle")
	defer remove_all(dir)

	filepath_a := join_path(dir, "lifecycle.txt")
	touch_file(filepath_a)

	// Create and destroy 20 watchers rapidly
	for i in 0..<20 {
		w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
		testing.expectf(t, err == .None, "rapid lifecycle %d: error %v", i, err)
		if err != nil { return }
		fsw.destroy(w)
	}

	// Final watcher should still work
	c: Collector
	collector_init(&c)
	defer collector_destroy(&c)
	_collector = &c

	w, err := fsw.watch_file_poll(filepath_a, collector_cb, 50 * time.Millisecond)
	testing.expectf(t, err == .None, "final watcher error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(150 * time.Millisecond)
	collector_clear(&c)

	write_file(filepath_a, "after rapid lifecycle")
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "final modify: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Modified, "lifecycle.txt"), "final modify: no Modified event")
}

// Overflow tracking globals
_overflow_received: bool
_overflow_mu: sync.Mutex

@(test)
test_overflow_tracking :: proc(t: ^testing.T) {
	dir := make_temp_dir(t, "overflow")
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
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil { return }
	defer fsw.destroy(w)

	time.sleep(100 * time.Millisecond)
	collector_clear(&c)

	// Create many files rapidly to try to trigger overflow
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
		fmt.println("  INFO: overflow event delivered")
	} else {
		fmt.println("  INFO: no overflow occurred (kernel buffer sufficient)")
	}

	// Verify watcher still works after the burst
	time.sleep(500 * time.Millisecond)
	collector_clear(&c)
	probe := join_path(dir, "PROBE_OVERFLOW.txt")
	touch_file(probe)
	testing.expect(t, collector_wait(&c, 1, 2 * time.Second), "post-burst probe: timeout")
	testing.expect(t, collector_has_kind_path(&c, .Added, "PROBE_OVERFLOW"), "post-burst probe: not detected")
}
