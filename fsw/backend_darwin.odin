package fsw

// macOS backend stub — FSEvents (dirs) + kqueue (files).
// TODO: implement

backend_file_init :: proc(w: ^Watcher_File) -> Error {
	return .Backend_Init_Failed
}

backend_file_destroy :: proc(w: ^Watcher_File) {
}

backend_dir_init :: proc(w: ^Watcher_Dir) -> Error {
	return .Backend_Init_Failed
}

backend_dir_destroy :: proc(w: ^Watcher_Dir) {
}

backend_rec_init :: proc(w: ^Watcher_Recursive) -> Error {
	return .Backend_Init_Failed
}

backend_rec_destroy :: proc(w: ^Watcher_Recursive) {
}

backend_rec_rescan :: proc(w: ^Watcher_Recursive) -> Error {
	return .Backend_Init_Failed
}
