// overlay-fuse provides a FUSE overlay filesystem for the macOS Claude sandbox.
//
// It overlays the host root filesystem with an ephemeral upper layer. Writes
// outside bind-through paths go to a tmpdir and are discarded on exit. Bind-
// through paths (workspace, ~/.claude) write directly to the host.
//
// Usage:
//
//	overlay-fuse -mountpoint /tmp/sandbox/merged \
//	  -upper /tmp/sandbox/upper \
//	  -lower / \
//	  -bind-through /Users/me/project,/Users/me/.claude
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

func main() {
	mountpoint := flag.String("mountpoint", "", "Where to mount the overlay filesystem")
	lower := flag.String("lower", "/", "Lower (read-only) layer path")
	upper := flag.String("upper", "", "Upper (ephemeral) layer path for copy-up writes")
	bindThrough := flag.String("bind-through", "", "Comma-separated paths that write directly to host")
	debug := flag.Bool("debug", false, "Enable FUSE debug logging")
	flag.Parse()

	if *mountpoint == "" || *upper == "" {
		fmt.Fprintf(os.Stderr, "Usage: overlay-fuse -mountpoint PATH -upper PATH [-lower PATH] [-bind-through PATH,...]\n")
		os.Exit(1)
	}

	// Parse bind-through paths
	var bindPaths []string
	if *bindThrough != "" {
		bindPaths = strings.Split(*bindThrough, ",")
	}

	root := NewOverlayRoot(*lower, *upper, bindPaths)

	server, err := fs.Mount(*mountpoint, root, &fs.Options{
		MountOptions: fuse.MountOptions{
			Debug:      *debug,
			AllowOther: true,
			FsName:     "overlay-fuse",
			Name:       "overlay-fuse",
		},
		// Use reasonable timeouts for a local overlay
		AttrTimeout:  nil, // no caching — always re-check host
		EntryTimeout: nil,
	})
	if err != nil {
		log.Fatalf("Mount failed: %v", err)
	}

	// Signal readiness to parent process via stdout
	fmt.Println("READY")
	os.Stdout.Sync()

	// Handle termination signals for clean unmount
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		server.Unmount()
	}()

	server.Wait()
}
