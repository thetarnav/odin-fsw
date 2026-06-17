package fsw

Event_Kind :: enum {
	Added,
	Removed,
	Modified,
	Renamed,
	Overflow,
	Invalidated,
}

Error :: enum {
	None,
	Invalid_Path,
	Backend_Init_Failed,
}

Event :: struct {
	kind:     Event_Kind,
	path:     string,
	old_path: string,
	is_dir:   bool,
}

Event_Callback :: proc(event: ^Event)
