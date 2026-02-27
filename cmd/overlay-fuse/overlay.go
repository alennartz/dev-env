package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// whiteoutPrefix is the standard overlayfs convention for marking deletions.
const whiteoutPrefix = ".wh."

// OverlayRoot holds the overlay configuration.
type OverlayRoot struct {
	Lower      string   // read-only base (host /)
	Upper      string   // ephemeral layer (tmpdir)
	BindPaths  []string // paths that write through to host
}

// OverlayNode is a node in the overlay filesystem tree.
type OverlayNode struct {
	fs.Inode
	root *OverlayRoot
}

// Compile-time interface checks.
var _ = (fs.NodeLookuper)((*OverlayNode)(nil))
var _ = (fs.NodeReaddirer)((*OverlayNode)(nil))
var _ = (fs.NodeGetattrer)((*OverlayNode)(nil))
var _ = (fs.NodeSetattrer)((*OverlayNode)(nil))
var _ = (fs.NodeOpener)((*OverlayNode)(nil))
var _ = (fs.NodeCreater)((*OverlayNode)(nil))
var _ = (fs.NodeMkdirer)((*OverlayNode)(nil))
var _ = (fs.NodeUnlinker)((*OverlayNode)(nil))
var _ = (fs.NodeRmdirer)((*OverlayNode)(nil))
var _ = (fs.NodeRenamer)((*OverlayNode)(nil))
var _ = (fs.NodeSymlinker)((*OverlayNode)(nil))
var _ = (fs.NodeReadlinker)((*OverlayNode)(nil))
var _ = (fs.NodeLinker)((*OverlayNode)(nil))
var _ = (fs.NodeStatfser)((*OverlayNode)(nil))

// NewOverlayRoot creates a new overlay root node.
func NewOverlayRoot(lower, upper string, bindPaths []string) *OverlayNode {
	return &OverlayNode{
		root: &OverlayRoot{
			Lower:     lower,
			Upper:     upper,
			BindPaths: bindPaths,
		},
	}
}

// --- Path resolution ---

// overlayPath returns the path of this node relative to the overlay root.
func (n *OverlayNode) overlayPath() string {
	return n.Path(n.Root())
}

// lowerPath returns the absolute path in the lower (host) layer.
func (n *OverlayNode) lowerPath() string {
	return filepath.Join(n.root.Lower, n.overlayPath())
}

// upperPath returns the absolute path in the upper (ephemeral) layer.
func (n *OverlayNode) upperPath() string {
	return filepath.Join(n.root.Upper, n.overlayPath())
}

// isBindThrough returns true if this node's path falls under a bind-through directory.
func (n *OverlayNode) isBindThrough() bool {
	p := "/" + n.overlayPath()
	for _, bp := range n.root.BindPaths {
		if p == bp || strings.HasPrefix(p, bp+"/") {
			return true
		}
	}
	return false
}

// writePath returns where writes for this node should go.
// Bind-through paths write to the lower (host) layer; others write to upper.
func (n *OverlayNode) writePath() string {
	if n.isBindThrough() {
		return n.lowerPath()
	}
	return n.upperPath()
}

// childWritePath returns the write path for a child name.
func (n *OverlayNode) childWritePath(name string) string {
	if n.isChildBindThrough(name) {
		return filepath.Join(n.lowerPath(), name)
	}
	return filepath.Join(n.upperPath(), name)
}

// isChildBindThrough checks if a child name falls under a bind-through path.
func (n *OverlayNode) isChildBindThrough(name string) bool {
	p := "/" + filepath.Join(n.overlayPath(), name)
	for _, bp := range n.root.BindPaths {
		if p == bp || strings.HasPrefix(p, bp+"/") || strings.HasPrefix(bp, p+"/") {
			return true
		}
	}
	return false
}

// hasWhiteout checks if a whiteout marker exists for a child name.
func (n *OverlayNode) hasWhiteout(name string) bool {
	wh := filepath.Join(n.upperPath(), whiteoutPrefix+name)
	_, err := os.Lstat(wh)
	return err == nil
}

// createWhiteout creates a whiteout marker for a child name.
func (n *OverlayNode) createWhiteout(name string) error {
	dir := n.upperPath()
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	wh := filepath.Join(dir, whiteoutPrefix+name)
	f, err := os.Create(wh)
	if err != nil {
		return err
	}
	return f.Close()
}

// removeWhiteout removes a whiteout marker for a child name.
func (n *OverlayNode) removeWhiteout(name string) {
	wh := filepath.Join(n.upperPath(), whiteoutPrefix+name)
	os.Remove(wh)
}

// effectivePath returns the path to use for reads: upper if exists, else lower.
// Returns "" if neither exists or if whited-out.
func (n *OverlayNode) effectivePath() string {
	up := n.upperPath()
	if _, err := os.Lstat(up); err == nil {
		return up
	}
	lp := n.lowerPath()
	if _, err := os.Lstat(lp); err == nil {
		return lp
	}
	return ""
}

// childEffectivePath returns the effective path for a child.
func (n *OverlayNode) childEffectivePath(name string) string {
	up := filepath.Join(n.upperPath(), name)
	if _, err := os.Lstat(up); err == nil {
		return up
	}
	lp := filepath.Join(n.lowerPath(), name)
	if _, err := os.Lstat(lp); err == nil {
		return lp
	}
	return ""
}

// ensureUpperDir creates the upper directory path for this node (for copy-up).
func (n *OverlayNode) ensureUpperDir() error {
	return os.MkdirAll(n.upperPath(), 0755)
}

// --- Copy-up ---

// copyUp copies a file from lower to upper layer on first write.
func (n *OverlayNode) copyUp() error {
	if n.isBindThrough() {
		return nil // bind-through paths don't need copy-up
	}
	up := n.upperPath()
	if _, err := os.Lstat(up); err == nil {
		return nil // already in upper
	}
	lp := n.lowerPath()
	info, err := os.Lstat(lp)
	if err != nil {
		return err
	}

	// Ensure parent directory exists in upper
	if err := os.MkdirAll(filepath.Dir(up), 0755); err != nil {
		return err
	}

	if info.IsDir() {
		return os.Mkdir(up, info.Mode().Perm())
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(lp)
		if err != nil {
			return err
		}
		return os.Symlink(target, up)
	}

	// Regular file: copy contents
	src, err := os.Open(lp)
	if err != nil {
		return err
	}
	defer src.Close()

	dst, err := os.OpenFile(up, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	defer dst.Close()

	if _, err := io.Copy(dst, src); err != nil {
		os.Remove(up)
		return err
	}

	// Preserve timestamps
	stat := info.Sys().(*syscall.Stat_t)
	ts := []syscall.Timespec{stat.Atimespec, stat.Mtimespec}
	return syscall.UtimesNano(up, ts)
}

// --- Node operations ---

func (n *OverlayNode) newChild() *OverlayNode {
	return &OverlayNode{root: n.root}
}

func fillAttrFromStat(out *fuse.Attr, st *syscall.Stat_t) {
	out.Ino = st.Ino
	out.Size = uint64(st.Size)
	out.Blocks = uint64(st.Blocks)
	out.Atime = uint64(st.Atimespec.Sec)
	out.Atimensec = uint32(st.Atimespec.Nsec)
	out.Mtime = uint64(st.Mtimespec.Sec)
	out.Mtimensec = uint32(st.Mtimespec.Nsec)
	out.Ctime = uint64(st.Ctimespec.Sec)
	out.Ctimensec = uint32(st.Ctimespec.Nsec)
	out.Mode = st.Mode
	out.Nlink = uint32(st.Nlink)
	out.Owner.Uid = st.Uid
	out.Owner.Gid = st.Gid
	out.Rdev = uint32(st.Rdev)
	out.Blksize = uint32(st.Blksize)
}

func (n *OverlayNode) Getattr(ctx context.Context, fh fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	p := n.effectivePath()
	if p == "" {
		return syscall.ENOENT
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)
	return fs.OK
}

func (n *OverlayNode) Setattr(ctx context.Context, fh fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	if err := n.copyUp(); err != nil {
		return fs.ToErrno(err)
	}
	p := n.writePath()

	if m, ok := in.GetMode(); ok {
		if err := syscall.Chmod(p, m); err != nil {
			return fs.ToErrno(err)
		}
	}
	if uid, ok := in.GetUID(); ok {
		gid := ^uint32(0)
		if g, ok2 := in.GetGID(); ok2 {
			gid = g
		}
		if err := syscall.Lchown(p, int(uid), int(gid)); err != nil {
			return fs.ToErrno(err)
		}
	} else if gid, ok := in.GetGID(); ok {
		if err := syscall.Lchown(p, -1, int(gid)); err != nil {
			return fs.ToErrno(err)
		}
	}
	if sz, ok := in.GetSize(); ok {
		if err := syscall.Truncate(p, int64(sz)); err != nil {
			return fs.ToErrno(err)
		}
	}
	if atime, ok := in.GetATime(); ok {
		mtime := atime
		if m, ok2 := in.GetMTime(); ok2 {
			mtime = m
		}
		ts := []syscall.Timespec{
			{Sec: atime.Unix(), Nsec: int64(atime.Nanosecond())},
			{Sec: mtime.Unix(), Nsec: int64(mtime.Nanosecond())},
		}
		if err := syscall.UtimesNano(p, ts); err != nil {
			return fs.ToErrno(err)
		}
	}

	return n.Getattr(ctx, fh, out)
}

func (n *OverlayNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	// Whiteout check: if deleted in upper, treat as nonexistent
	if n.hasWhiteout(name) {
		return nil, syscall.ENOENT
	}

	// Skip whiteout files themselves
	if strings.HasPrefix(name, whiteoutPrefix) {
		return nil, syscall.ENOENT
	}

	p := n.childEffectivePath(name)
	if p == "" {
		return nil, syscall.ENOENT
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}

	fillAttrFromStat(&out.Attr, &st)

	child := n.NewInode(ctx, n.newChild(), fs.StableAttr{
		Mode: st.Mode,
		Ino:  st.Ino,
	})
	return child, fs.OK
}

func (n *OverlayNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	// Merge entries from lower and upper, applying whiteouts
	entries := make(map[string]fuse.DirEntry)

	// Read lower layer
	lp := n.lowerPath()
	if dirEntries, err := os.ReadDir(lp); err == nil {
		for _, de := range dirEntries {
			name := de.Name()
			if strings.HasPrefix(name, whiteoutPrefix) {
				continue
			}
			info, err := de.Info()
			if err != nil {
				continue
			}
			st := info.Sys().(*syscall.Stat_t)
			entries[name] = fuse.DirEntry{
				Name: name,
				Ino:  st.Ino,
				Mode: st.Mode,
			}
		}
	}

	// Read upper layer (overrides lower)
	up := n.upperPath()
	if dirEntries, err := os.ReadDir(up); err == nil {
		for _, de := range dirEntries {
			name := de.Name()
			// Process whiteouts: remove the whited-out entry
			if strings.HasPrefix(name, whiteoutPrefix) {
				origName := strings.TrimPrefix(name, whiteoutPrefix)
				delete(entries, origName)
				continue
			}
			info, err := de.Info()
			if err != nil {
				continue
			}
			st := info.Sys().(*syscall.Stat_t)
			entries[name] = fuse.DirEntry{
				Name: name,
				Ino:  st.Ino,
				Mode: st.Mode,
			}
		}
	}

	// Apply whiteouts from upper to lower entries
	if dirEntries, err := os.ReadDir(up); err == nil {
		for _, de := range dirEntries {
			name := de.Name()
			if strings.HasPrefix(name, whiteoutPrefix) {
				origName := strings.TrimPrefix(name, whiteoutPrefix)
				delete(entries, origName)
			}
		}
	}

	result := make([]fuse.DirEntry, 0, len(entries))
	for _, e := range entries {
		result = append(result, e)
	}
	return fs.NewListDirStream(result), fs.OK
}

func (n *OverlayNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	// Remove whiteout if creating over a previously deleted file
	n.removeWhiteout(name)

	p := n.childWritePath(name)
	if !n.isChildBindThrough(name) {
		if err := n.ensureUpperDir(); err != nil {
			return nil, nil, 0, fs.ToErrno(err)
		}
	}

	fd, err := syscall.Open(p, int(flags)|os.O_CREATE|os.O_WRONLY, mode)
	if err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		syscall.Close(fd)
		return nil, nil, 0, fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)

	child := n.NewInode(ctx, n.newChild(), fs.StableAttr{
		Mode: st.Mode,
		Ino:  st.Ino,
	})
	fh := &overlayFileHandle{fd: fd, mu: &sync.Mutex{}}
	return child, fh, 0, fs.OK
}

func (n *OverlayNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	isWrite := flags&(syscall.O_WRONLY|syscall.O_RDWR|syscall.O_TRUNC|syscall.O_APPEND) != 0

	if isWrite {
		if err := n.copyUp(); err != nil {
			return nil, 0, fs.ToErrno(err)
		}
		p := n.writePath()
		fd, err := syscall.Open(p, int(flags), 0)
		if err != nil {
			return nil, 0, fs.ToErrno(err)
		}
		return &overlayFileHandle{fd: fd, mu: &sync.Mutex{}}, 0, fs.OK
	}

	// Read-only: use effective path (upper if copied up, else lower)
	p := n.effectivePath()
	if p == "" {
		return nil, 0, syscall.ENOENT
	}
	fd, err := syscall.Open(p, int(flags), 0)
	if err != nil {
		return nil, 0, fs.ToErrno(err)
	}
	return &overlayFileHandle{fd: fd, mu: &sync.Mutex{}}, 0, fs.OK
}

func (n *OverlayNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	n.removeWhiteout(name)

	p := n.childWritePath(name)
	if !n.isChildBindThrough(name) {
		if err := n.ensureUpperDir(); err != nil {
			return nil, fs.ToErrno(err)
		}
	}

	if err := syscall.Mkdir(p, mode); err != nil {
		return nil, fs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)

	child := n.NewInode(ctx, n.newChild(), fs.StableAttr{
		Mode: st.Mode,
		Ino:  st.Ino,
	})
	return child, fs.OK
}

func (n *OverlayNode) Unlink(ctx context.Context, name string) syscall.Errno {
	// If file exists in upper (or is bind-through), remove it directly
	if n.isChildBindThrough(name) {
		p := filepath.Join(n.lowerPath(), name)
		return fs.ToErrno(syscall.Unlink(p))
	}

	up := filepath.Join(n.upperPath(), name)
	if _, err := os.Lstat(up); err == nil {
		if err := syscall.Unlink(up); err != nil {
			return fs.ToErrno(err)
		}
	}

	// If it existed in lower, create a whiteout
	lp := filepath.Join(n.lowerPath(), name)
	if _, err := os.Lstat(lp); err == nil {
		if err := n.createWhiteout(name); err != nil {
			return fs.ToErrno(err)
		}
	}
	return fs.OK
}

func (n *OverlayNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	if n.isChildBindThrough(name) {
		p := filepath.Join(n.lowerPath(), name)
		return fs.ToErrno(syscall.Rmdir(p))
	}

	up := filepath.Join(n.upperPath(), name)
	if _, err := os.Lstat(up); err == nil {
		if err := syscall.Rmdir(up); err != nil {
			return fs.ToErrno(err)
		}
	}

	lp := filepath.Join(n.lowerPath(), name)
	if _, err := os.Lstat(lp); err == nil {
		if err := n.createWhiteout(name); err != nil {
			return fs.ToErrno(err)
		}
	}
	return fs.OK
}

func (n *OverlayNode) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	// Copy-up the source if needed
	child := n.GetChild(name)
	if child != nil {
		childNode := child.Operations().(*OverlayNode)
		if err := childNode.copyUp(); err != nil {
			return fs.ToErrno(err)
		}
	}

	np := newParent.(*OverlayNode)
	oldPath := n.childWritePath(name)
	newPath := np.childWritePath(newName)

	// Ensure destination parent exists in upper
	if !np.isChildBindThrough(newName) {
		if err := np.ensureUpperDir(); err != nil {
			return fs.ToErrno(err)
		}
	}

	if err := syscall.Rename(oldPath, newPath); err != nil {
		return fs.ToErrno(err)
	}

	// Whiteout old location if it was in lower
	lp := filepath.Join(n.lowerPath(), name)
	if _, err := os.Lstat(lp); err == nil {
		n.createWhiteout(name)
	}

	// Remove whiteout at new location
	np.removeWhiteout(newName)

	return fs.OK
}

func (n *OverlayNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	n.removeWhiteout(name)

	p := n.childWritePath(name)
	if !n.isChildBindThrough(name) {
		if err := n.ensureUpperDir(); err != nil {
			return nil, fs.ToErrno(err)
		}
	}

	if err := syscall.Symlink(target, p); err != nil {
		return nil, fs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)

	child := n.NewInode(ctx, n.newChild(), fs.StableAttr{
		Mode: st.Mode,
		Ino:  st.Ino,
	})
	return child, fs.OK
}

func (n *OverlayNode) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	p := n.effectivePath()
	if p == "" {
		return nil, syscall.ENOENT
	}
	target, err := os.Readlink(p)
	if err != nil {
		return nil, fs.ToErrno(err)
	}
	return []byte(target), fs.OK
}

func (n *OverlayNode) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	targetNode := target.(*OverlayNode)
	if err := targetNode.copyUp(); err != nil {
		return nil, fs.ToErrno(err)
	}
	n.removeWhiteout(name)

	if !n.isChildBindThrough(name) {
		if err := n.ensureUpperDir(); err != nil {
			return nil, fs.ToErrno(err)
		}
	}

	targetPath := targetNode.writePath()
	linkPath := n.childWritePath(name)

	if err := syscall.Link(targetPath, linkPath); err != nil {
		return nil, fs.ToErrno(err)
	}

	var st syscall.Stat_t
	if err := syscall.Lstat(linkPath, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)

	child := n.NewInode(ctx, n.newChild(), fs.StableAttr{
		Mode: st.Mode,
		Ino:  st.Ino,
	})
	return child, fs.OK
}

func (n *OverlayNode) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	p := n.effectivePath()
	if p == "" {
		p = n.root.Lower
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(p, &stat); err != nil {
		return fs.ToErrno(err)
	}
	out.Blocks = stat.Blocks
	out.Bfree = stat.Bfree
	out.Bavail = stat.Bavail
	out.Files = stat.Files
	out.Ffree = stat.Ffree
	out.Bsize = uint32(stat.Bsize)
	out.NameLen = 255
	out.Frsize = uint32(stat.Bsize)
	return fs.OK
}

// --- File handle ---

type overlayFileHandle struct {
	fd int
	mu *sync.Mutex
}

var _ = (fs.FileReader)((*overlayFileHandle)(nil))
var _ = (fs.FileWriter)((*overlayFileHandle)(nil))
var _ = (fs.FileGetattrer)((*overlayFileHandle)(nil))
var _ = (fs.FileFlusher)((*overlayFileHandle)(nil))
var _ = (fs.FileFsyncer)((*overlayFileHandle)(nil))
var _ = (fs.FileReleaser)((*overlayFileHandle)(nil))
var _ = (fs.FileLseeker)((*overlayFileHandle)(nil))

func (fh *overlayFileHandle) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	buf := make([]byte, len(dest))
	n, err := syscall.Pread(fh.fd, buf, off)
	if err != nil {
		return nil, fs.ToErrno(err)
	}
	return fuse.ReadResultData(buf[:n]), fs.OK
}

func (fh *overlayFileHandle) Write(ctx context.Context, data []byte, off int64) (uint32, syscall.Errno) {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	n, err := syscall.Pwrite(fh.fd, data, off)
	if err != nil {
		return 0, fs.ToErrno(err)
	}
	return uint32(n), fs.OK
}

func (fh *overlayFileHandle) Getattr(ctx context.Context, out *fuse.AttrOut) syscall.Errno {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	var st syscall.Stat_t
	if err := syscall.Fstat(fh.fd, &st); err != nil {
		return fs.ToErrno(err)
	}
	fillAttrFromStat(&out.Attr, &st)
	return fs.OK
}

func (fh *overlayFileHandle) Flush(ctx context.Context) syscall.Errno {
	return fs.OK
}

func (fh *overlayFileHandle) Fsync(ctx context.Context, flags uint32) syscall.Errno {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	return fs.ToErrno(syscall.Fsync(fh.fd))
}

func (fh *overlayFileHandle) Release(ctx context.Context) syscall.Errno {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	if fh.fd != -1 {
		syscall.Close(fh.fd)
		fh.fd = -1
	}
	return fs.OK
}

func (fh *overlayFileHandle) Lseek(ctx context.Context, off uint64, whence uint32) (uint64, syscall.Errno) {
	fh.mu.Lock()
	defer fh.mu.Unlock()
	newOff, err := syscall.Seek(fh.fd, int64(off), int(whence))
	if err != nil {
		return 0, fs.ToErrno(err)
	}
	return uint64(newOff), fs.OK
}
