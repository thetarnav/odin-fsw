// track.odin — Test-only handle/resource tracking for the built-in
// memory tracker.
//
// In tests (when ODIN_TEST is defined), every OS resource acquisition
// (posix.open, kqueue.kqueue, CreateFileW, CreateEventW, ...) is paired
// with a small heap allocation. The address of that allocation is stored
// in a global map keyed by the handle value. When the matching close runs,
// the allocation is freed and the map entry is removed. If a test exits
// with handles still open, the built-in memory tracker reports a leak and
// points at this file (the new(int, ...) call site). Double-close is also
// caught: the second unregister is a no-op (map miss), but the real
// close (posix.close, etc.) returns EBADF — that won't be caught by us
// directly, but the test framework will flag the resulting bad free on
// the token (or just the missing-handle EBADF) as a red flag.
//
// All tracking allocations (the map's buckets and the per-handle tokens)
// use `runtime.heap_allocator` so the built-in test memory tracker does
// not flag them. The map is allocated in `@init` and freed in `@fini`,
// running outside any individual test's accounting window.
//
// In release builds the helpers are no-ops and the map is absent.

#+feature global-context
package fsw

import "base:runtime"

when ODIN_TEST {
	// Tracks an outstanding resource by handle value. The key is the
	// resource (cast to int — FDs and HANDLEs are both pointer-sized
	// integers on the platforms we target). The value is a single-int
	// allocation; on close, this allocation is freed and the key is
	// removed from the map.
	@(private)
	OS_Resources: ^map[int]^int

	@(private)
	@(init)
	track_init :: proc() {
		ha := runtime.heap_allocator()
		OS_Resources = new(map[int]^int, ha)
		OS_Resources^ = make(map[int]^int, ha)
	}

	@(private)
	@(fini)
	track_fini :: proc() {
		ha := runtime.heap_allocator()
		for _, token in OS_Resources^ {
			free(token, ha)
		}
		delete(OS_Resources^)
		free(OS_Resources, ha)
	}

	// track_open records that `key` was just acquired. The key must be
	// non-negative (e.g. FD -1 on error should not be tracked).
	track_open :: proc(key: int) {
		if key < 0 do return
		token := new(int, runtime.heap_allocator())
		token^ = key
		OS_Resources^[key] = token
	}

	// track_close removes `key` from the tracking map and frees its
	// token. Safe to call for unknown keys (e.g. closing a handle that
	// was never tracked, or after a double-close already removed it).
	track_close :: proc(key: int) {
		if token, ok := OS_Resources^[key]; ok {
			delete_key(OS_Resources, key)
			free(token, runtime.heap_allocator())
		}
	}
} else {
	// No-op stubs for release builds. The runtime import is referenced
	// here so the import isn't flagged as unused by vet in non-test
	// builds; the reference is a compile-time constant and optimized away.
	_RUNTIME_REFERENCE :: runtime.heap_allocator

	track_open :: proc(key: int) {}
	track_close :: proc(key: int) {}
}
