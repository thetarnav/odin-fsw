// main.odin — Demo CLI for the odin-fsw file watcher.
//
// Usage: fsw_demo <glob-pattern> [poll-interval-ms]
//
// Example: fsw_demo "src/*.odin" 100
//
// Watches files matching the glob and prints events to stdout.
// Press Ctrl-C to stop.

package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import fsw ".."

main :: proc () {
	args := os.args[1:]
	if len(args) < 1 {
		fmt.panicf("usage: fsw_demo <glob-pattern> [poll-interval-ms]\n")
	}

	pattern := args[0]

	poll_ms: int = 100
	if len(args) >= 2 {
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 1 {
			fmt.panicf("invalid poll interval: %s\n", args[1])
		}
		poll_ms = n
	}

	w, err := fsw.watch_glob(pattern)
	if err != .None {
		fmt.panicf("watch_glob(%q) failed: %v\n", pattern, err)
	}
	defer fsw.destroy(w)

	fmt.printfln("watching %q (poll %dms) — Ctrl-C to stop", pattern, poll_ms)
	fmt.println("---")

	interval := time.Duration(poll_ms) * time.Millisecond

	for {
		events := fsw.get_events(w, context.temp_allocator)
		for ev in events {
			suffix := ""
			if ev.is_dir do suffix = "/"
			fmt.printfln("[%v] %s%s", ev.kind, ev.path, suffix)
		}
		time.sleep(interval)
		free_all(context.temp_allocator)
	}
}
