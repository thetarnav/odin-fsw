// event.odin — Core event types.
//
// This file defines the public types that represent filesystem events:
//   - Event_Kind: the type of change (Added, Removed, Modified, Renamed, Overflow, Invalidated)
//   - Error: error codes returned by constructors and rescan
//   - Event: a single filesystem event with kind, path, and metadata
//
// These types are used by all watcher variants and backends.

package fsw

// Event_Kind describes the type of filesystem change detected.
Event_Kind :: enum {
	Added,        // A new file or directory was created.
	Removed,      // A file or directory was deleted.
	Modified,     // A file's content or metadata changed.
	Renamed,      // A file or directory was moved/renamed.
	Overflow,     // The OS event queue overflowed; events may have been lost.
	Invalidated,  // The watch target was unmounted or became invalid.
}

// Error codes returned by watcher constructors and rescan procs.
Error :: enum {
	None,                // No error.
	Invalid_Path,        // The path does not exist or cannot be resolved.
	Backend_Init_Failed, // The OS-native watcher could not be created.
}

// Event represents a single filesystem change. The path string is only
// valid until the next call to get_event/get_events on the same watcher
// (or until destroy). Clone it if you need to keep it past that.
Event :: struct {
	kind:     Event_Kind, // What happened.
	path:     string,     // Absolute path of the affected file/directory.
	old_path: string,     // Previous path (for Renamed events, currently unused).
	is_dir:   bool,       // True if the target is a directory.
}
