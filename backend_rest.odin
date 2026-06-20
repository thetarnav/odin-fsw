// backend_rest.odin — Fallback for platforms without a dedicated native backend.
//
// This file provides a stub implementation of the platform-specific types
// and procs for targets that are not Linux, Darwin, FreeBSD, or Windows.
// It is excluded from compilation on those targets via build tags.

#+build !linux
#+build !darwin
#+build !freebsd
#+build !windows
package fsw

// === Platform-specific native data ===
// Empty stubs for unsupported targets. The native backends are not available
// on these platforms; users would need to use the polling backend.

Native_File      :: struct {}
Native_Dir       :: struct {}
Native_Recursive :: struct {}

// === Backend procs ===
// These return .Backend_Init_Failed to signal that the native backend is
// unavailable on this platform. Users should fall back to the polling
// watchers (watch_file_poll, watch_dir_poll, etc.) on these platforms.

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	return .Backend_Init_Failed
}

backend_file_destroy :: proc(w: ^Watcher_File) {}

backend_file_get_event :: proc(w: ^Watcher_File) -> (Event, bool) {
	return {}, false
}

backend_file_get_events :: proc(w: ^Watcher_File) -> []Event {
	return nil
}

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	return .Backend_Init_Failed
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {}

backend_dir_get_event :: proc(w: ^Watcher_Dir) -> (Event, bool) {
	return {}, false
}

backend_dir_get_events :: proc(w: ^Watcher_Dir) -> []Event {
	return nil
}

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	return .Backend_Init_Failed
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	return .None
}

backend_rec_get_event :: proc(w: ^Watcher_Recursive) -> (Event, bool) {
	return {}, false
}

backend_rec_get_events :: proc(w: ^Watcher_Recursive) -> []Event {
	return nil
}

backend_rec_native_cleanup :: proc(w: ^Watcher_Recursive) {}
