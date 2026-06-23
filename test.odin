#+test
#+private package
package fsw

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// === Test helpers ===

make_temp_dir :: proc (t: ^testing.T, prefix: string) -> string {
	name := fmt.tprintf("fsw_test_{}_{}", prefix, time.time_to_unix(time.now()))
	temp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if temp_dir == "" do temp_dir = os.get_env("TEMP", context.temp_allocator)
	if temp_dir == "" do temp_dir = os.get_env("TMP", context.temp_allocator)
	if temp_dir == "" do temp_dir = "/tmp"
	dir, _ := os.join_path({temp_dir, name}, context.temp_allocator)
	err := os.mkdir(dir)
	testing.expectf(t, err == nil, "cannot create temp dir %s: %v", dir, err)
	return dir
}

remove_all :: proc (dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for entry in entries {
		if entry.name == "." || entry.name == ".." do continue
		full, _ := os.join_path({dir, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			remove_all(full)
		} else {
			os.remove(full)
		}
	}
	os.remove(dir)
}

write_file :: proc (path: string, content: string) {
	fd, err := os.create(path)
	if err != nil do return
	os.write(fd, transmute([]byte)content)
	os.close(fd)
}

// === Poll-and-collect helper ===
//
// Drives a watcher for up to `timeout` duration, accumulating events into
// `collected`. The predicate decides which events are interesting. Stops
// as soon as the predicate returns true.

// collect_events drives the watcher in a loop until timeout or found.
// `polling_interval` is how long to sleep between get_events calls.
collect_events :: proc (
	t: ^testing.T,
	w: ^$T,
	timeout: time.Duration,
	polling_interval: time.Duration,
	predicate: proc (e: ^Event) -> bool,
) -> (events: []Event, found: bool) {

	events_arr := make([dynamic]Event, 0, 16, context.temp_allocator)
	deadline := time.time_to_unix(time.now()) + i64(timeout / time.Second) + 1

	iterations: int
	ev_loop: for time.time_to_unix(time.now()) < deadline {

		// get events with defailt allocator to track proper event freeing
		batch := get_events(w)
		defer delete_events(batch)

		iterations += 1
		for &e in batch {
			append(&events_arr, clone_event(e, context.temp_allocator))
			if predicate(&e) {
				found = true
				break ev_loop
			}
		}
		time.sleep(polling_interval)
	}
	if !found {
		fmt.eprintf("  [debug] collect_events timed out after %v (%d iterations, %d events)\n", timeout, iterations, len(events))
	}

	return events_arr[:], found
}

// === Tests ===

@(test)
test_poll_file_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "poll_file")
	defer remove_all(dir)

	filepath_a, _ := os.join_path({dir, "a.txt"}, context.temp_allocator)
	write_file(filepath_a, "hello")

	w, err := watch_file_poll(filepath_a)
	testing.expectf(t, err == .None, "watch_file_poll error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Modify file
	write_file(filepath_a, "modified content")
	events, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "modify: timeout")
	testing.expect(t, len(events) > 0, "modify: no events")

	// 2. Modify file again
	write_file(filepath_a, "modified content again")
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "modify 2: timeout")
	testing.expect(t, len(events) > 0, "modify 2: no events")

	// 3. Delete file
	os.remove(filepath_a)
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "delete: timeout")
	testing.expect(t, len(events) > 0, "delete: no events")

	// 4. Recreate file — polling watcher should emit .Added
	write_file(filepath_a, "recreated content")
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "add after delete: timeout")
	testing.expect(t, len(events) > 0, "add after delete: no events")

	// 5. Modify after recreate
	write_file(filepath_a, "modified after recreate")
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "modify after recreate: timeout")
	testing.expect(t, len(events) > 0, "modify after recreate: no events")
}

@(test)
test_poll_dir_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "poll_dir")
	defer remove_all(dir)

	w, err := watch_dir_poll(dir)
	testing.expectf(t, err == .None, "watch_dir_poll error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Create file
	file_a, _ := os.join_path({dir, "new.txt"}, context.temp_allocator)
	write_file(file_a, "hello")
	events, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "create: timeout")
	testing.expect(t, len(events) > 0, "create: no events")

	// 2. Modify file
	write_file(file_a, "changed")
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "modify: timeout")
	testing.expect(t, len(events) > 0, "modify: no events")

	// 3. Delete file
	os.remove(file_a)
	events, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "delete: timeout")
	testing.expect(t, len(events) > 0, "delete: no events")
}

@(test)
test_poll_recursive_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "poll_rec")
	defer remove_all(dir)

	w, err := watch_dir_poll_recursive(dir)
	testing.expectf(t, err == .None, "watch_dir_poll_recursive error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Create subdir + file in subdir
	subdir, _ := os.join_path({dir, "sub"}, context.temp_allocator)
	os.mkdir(subdir)

	nested_file, _ := os.join_path({subdir, "deep.txt"}, context.temp_allocator)
	write_file(nested_file, "hello")

	events, found := collect_events(t, &w, 3 * time.Second, 50 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "deep.txt")
	})
	testing.expect(t, found, "nested create: timeout")

	// Also check subdir was reported
	has_subdir := false
	for ev in events {
		if ev.kind == .Added && strings.contains(ev.path, "sub") {
			has_subdir = true
			break
		}
	}
	testing.expect(t, has_subdir, "subdir create: no Added event")

	// 2. Modify nested file
	write_file(nested_file, "updated deep content")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "deep.txt")
	})
	testing.expect(t, found, "nested modify: timeout")

	// 3. Delete nested file
	os.remove(nested_file)
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "deep.txt")
	})
	testing.expect(t, found, "nested delete: timeout")
}

@(test)
test_native_file_watcher :: proc (t: ^testing.T) {

	dir := make_temp_dir(t, "native_file_watcher")
	defer remove_all(dir)

	filepath_a, _ := os.join_path({dir, "a.txt"}, context.temp_allocator)
	write_file(filepath_a, "hello")

	w, err := watch_file(filepath_a)
	testing.expectf(t, err == .None, "watch_file error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Modify file
	write_file(filepath_a, "first modification")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "modify before delete: timeout")

	// 2. Delete file
	os.remove(filepath_a)
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "delete: timeout")

	// 3. Recreate file
	write_file(filepath_a, "recreated")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "recreate: timeout")

	// 4. Modify file again
	write_file(filepath_a, "modified after recreate")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "a.txt")
	})
	testing.expect(t, found, "modify after recreate: timeout")
}

@(test)
test_native_dir_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "native_dir")
	defer remove_all(dir)

	w, err := watch_dir(dir)
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Create file
	file_a, _ := os.join_path({dir, "test.txt"}, context.temp_allocator)
	write_file(file_a, "hello")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "test.txt")
	})
	testing.expect(t, found, "create: timeout")

	// 2. Delete file
	os.remove(file_a)
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "test.txt")
	})
	testing.expect(t, found, "delete: timeout")
}

@(test)
test_native_recursive_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "native_rec")
	defer remove_all(dir)

	w, err := watch_dir_recursive(dir)
	testing.expectf(t, err == .None, "watch_dir_recursive error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Create subdir
	subdir, _ := os.join_path({dir, "sub"}, context.temp_allocator)
	os.mkdir(subdir)
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "sub")
	})
	testing.expect(t, found, "subdir create: timeout")

	// 2. Create file in subdir (auto-watched by recursive)
	nested, _ := os.join_path({subdir, "nested.txt"}, context.temp_allocator)
	write_file(nested, "hello")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "nested.txt")
	})
	testing.expect(t, found, "nested create: timeout")

	// 3. Modify nested file
	time.sleep(50 * time.Millisecond)
	write_file(nested, "updated")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "nested.txt")
	})
	testing.expect(t, found, "nested modify: timeout")

	// 4. Delete nested file
	os.remove(nested)
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "nested.txt")
	})
	testing.expect(t, found, "nested delete: timeout")
}

@(test)
test_glob_watcher :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "glob")
	defer remove_all(dir)

	// Create a file that matches *.txt BEFORE watcher starts (initial scan)
	pre_existing, _ := os.join_path({dir, "pre.txt"}, context.temp_allocator)
	write_file(pre_existing, "existing")

	pattern, _ := os.join_path({dir, "*.txt"}, context.temp_allocator)
	w, err := watch_glob(pattern)
	testing.expectf(t, err == .None, "watch_glob error: %v", err)
	if err != nil do return
	defer destroy(w)

	// 1. Create a new .txt file (should match)
	new_txt, _ := os.join_path({dir, "new.txt"}, context.temp_allocator)
	write_file(new_txt, "hello")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "matching create: timeout")

	// 2. Create a .log file (should NOT match *.txt)
	// We just verify no event with .log comes through within a short window.
	new_log, _ := os.join_path({dir, "test.log"}, context.temp_allocator)
	write_file(new_log, "log data")
	events, _ := collect_events(t, &w, 300 * time.Millisecond, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return false // never match
	})
	for ev in events {
		testing.expect(t, !strings.contains(ev.path, ".log"), "non-matching .log file leaked an event")
	}

	// 3. Modify the .txt file (should match)
	time.sleep(50 * time.Millisecond)
	write_file(new_txt, "modified")
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "matching modify: timeout")

	// 4. Delete the .txt file (should match)
	os.remove(new_txt)
	_, found = collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Removed && strings.contains(e.path, "new.txt")
	})
	testing.expect(t, found, "matching delete: timeout")
}

@(test)
test_stress_many_files :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "stress_many")
	defer remove_all(dir)

	w, err := watch_dir(dir)
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil { return }
	defer destroy(w)

	// Create 50 files rapidly
	for i in 0..<50 {
		name := fmt.tprintf("stress_{}.txt", i)
		path, _ := os.join_path({dir, name}, context.temp_allocator)
		write_file(path, "hello")
	}

	// Stop collecting as soon as we've seen 50 matching events. The
	// counter is passed via context.user_ptr (Odin procs don't capture
	// closures). Returning `true` from the predicate short-circuits
	// the collect_events loop, so the test only takes as long as
	// needed instead of always running out the full 5 s timeout.
	added_count := 0
	context.user_ptr = &added_count
	_, found_stress := collect_events(t, &w, 5 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		cnt := cast(^int)context.user_ptr
		if e.kind == .Added && strings.contains(e.path, "stress_") {
			cnt^ += 1
			return cnt^ >= 50
		}
		return false
	})
	context.user_ptr = nil
	testing.expect(t, found_stress, fmt.tprintf("stress: only saw %d Added events, expected >= 50", added_count))

	// Verify watcher is still alive — create one more file with a unique name
	probe, _ := os.join_path({dir, "PROBE_AFTER_STRESS.txt"}, context.temp_allocator)
	write_file(probe, "hello")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "PROBE_AFTER_STRESS")
	})
	testing.expect(t, found, "post-stress probe: timeout")
}

@(test)
test_stress_rapid_lifecycle :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "stress_lifecycle")
	defer remove_all(dir)

	filepath_a, _ := os.join_path({dir, "lifecycle.txt"}, context.temp_allocator)
	write_file(filepath_a, "hello")

	// Create and destroy 20 watchers rapidly
	for i in 0..<20 {
		w, err := watch_file_poll(filepath_a)
		testing.expectf(t, err == .None, "rapid lifecycle %d: error %v", i, err)
		if err != nil { return }
		destroy(w)
	}

	// Final watcher should still work
	w, err := watch_file_poll(filepath_a)
	testing.expectf(t, err == .None, "final watcher error: %v", err)
	if err != nil { return }
	defer destroy(w)

	write_file(filepath_a, "after rapid lifecycle")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Modified && strings.contains(e.path, "lifecycle.txt")
	})
	testing.expect(t, found, "final modify: timeout")
}

@(test)
test_overflow_tracking :: proc (t: ^testing.T) {
	dir := make_temp_dir(t, "overflow")
	defer remove_all(dir)

	w, err := watch_dir(dir)
	testing.expectf(t, err == .None, "watch_dir error: %v", err)
	if err != nil do return
	defer destroy(w)

	// Create many files rapidly to try to trigger overflow
	for i in 0..<200 {
		name := fmt.tprintf("ovf_{}.txt", i)
		path, _ := os.join_path({dir, name}, context.temp_allocator)
		write_file(path, "hello")
	}

	// Look for an Overflow event, stopping as soon as one is seen. If
	// none is seen, stop after ~500 events (the burst produced ~600 in
	// practice) so the test doesn't sit idle for the full timeout. The
	// counter is passed via context.user_ptr (Odin procs don't capture
	// closures).
	event_count := 0
	context.user_ptr = &event_count
	_, had_overflow := collect_events(t, &w, 5 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		cnt := cast(^int)context.user_ptr
		cnt^ += 1
		if e.kind == .Overflow do return true
		if cnt^ >= 500 do return true
		return false
	})
	context.user_ptr = nil
	if had_overflow {
		fmt.println("  INFO: overflow event delivered")
	} else {
		fmt.println("  INFO: no overflow occurred (kernel buffer sufficient)")
	}

	// Verify watcher still works after the burst
	probe, _ := os.join_path({dir, "PROBE_OVERFLOW.txt"}, context.temp_allocator)
	write_file(probe, "hello")
	_, found := collect_events(t, &w, 2 * time.Second, 10 * time.Millisecond, proc (e: ^Event) -> bool {
		return e.kind == .Added && strings.contains(e.path, "PROBE_OVERFLOW")
	})
	testing.expect(t, found, "post-burst probe: timeout")
}
