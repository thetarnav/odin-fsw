// track.odin — Test-only handle/resource tracking.
// Watchers have a map [os handle -> open call location]
// Each open() call expects one close() call otherwise it errors
// tracking must be started with track_start and ended with track_end.

#+private package
package fsw

@require import "base:runtime"
@require import "core:log"

Track_Resources :: (map[int]runtime.Source_Code_Location when ODIN_TEST else struct {})

when ODIN_TEST {
	_track_start :: proc (resources: ^Track_Resources, loc: runtime.Source_Code_Location) {
		resources^ = make(Track_Resources, loc=loc)
	}
	_track_end :: proc (resources: ^Track_Resources, loc: runtime.Source_Code_Location) {
		for _, token_loc in resources {
			log.errorf("Resource not closed", location=token_loc)
		}
		delete(resources^, loc=loc)
	}
	_track_open :: proc (resources: ^Track_Resources, #any_int key: int, loc: runtime.Source_Code_Location) {
		if key < 0 do return
		resources[key] = loc
	}
	_track_close :: proc (resources: ^Track_Resources, #any_int key: int, loc: runtime.Source_Code_Location) {
		if key < 0 do return
		if _, in_map := resources[key]; in_map {
			delete_key(resources, key)
		} else {
			log.errorf("Unopened resource closed", location=loc)
		}
	}
}

track_start :: proc (w: ^$W, loc := #caller_location) {
	when ODIN_TEST do _track_start(&w._track_resources, loc=loc)
}
track_end :: proc (w: ^$W, loc := #caller_location) {
	when ODIN_TEST do _track_end(&w._track_resources, loc=loc)
}
track_open :: proc (w: ^$W, key: $T, loc := #caller_location) {
	when ODIN_TEST do _track_open(&w._track_resources, auto_cast key, loc)
}
track_close :: proc (w: ^$W, key: $T, loc := #caller_location) {
	when ODIN_TEST do _track_close(&w._track_resources, auto_cast key, loc)
}
