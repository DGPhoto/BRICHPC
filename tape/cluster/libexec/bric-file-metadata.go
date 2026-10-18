package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "BRIC file-metadata 34R2rc3"

type envelope struct {
	Version int               `json:"v"`
	Xattrs  map[string]string `json:"xattrs,omitempty"`
}

func selected(name string) bool {
	return strings.HasPrefix(name, "user.") || name == "system.posix_acl_access" || name == "system.posix_acl_default" || name == "system.nfs4_acl"
}

func listXattrs(path string) ([]string, error) {
	n, err := syscall.Listxattr(path, nil)
	if err != nil {
		if err == syscall.ENOTSUP || err == syscall.EOPNOTSUPP {
			return nil, nil
		}
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	buf := make([]byte, n)
	n, err = syscall.Listxattr(path, buf)
	if err != nil {
		return nil, err
	}
	out := []string{}
	start := 0
	for i := 0; i < n; i++ {
		if buf[i] == 0 {
			if i > start {
				out = append(out, string(buf[start:i]))
			}
			start = i + 1
		}
	}
	return out, nil
}

func getXattr(path, name string) ([]byte, error) {
	n, err := syscall.Getxattr(path, name, nil)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, n)
	n, err = syscall.Getxattr(path, name, buf)
	if err != nil {
		return nil, err
	}
	return buf[:n], nil
}

func capture(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return errors.New("metadata capture requires regular file")
	}
	env := envelope{Version: 1, Xattrs: map[string]string{}}
	names, err := listXattrs(path)
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		if !selected(name) {
			continue
		}
		v, e := getXattr(path, name)
		if e != nil {
			return fmt.Errorf("getxattr %s: %w", name, e)
		}
		env.Xattrs[name] = base64.StdEncoding.EncodeToString(v)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return err
	}
	fmt.Printf("%04o\t%d\t%s\n", st.Mode().Perm(), st.ModTime().Unix(), base64.StdEncoding.EncodeToString(raw))
	return nil
}

func degradable(err error) bool {
	return errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EINVAL)
}

func aclXattr(name string) bool {
	return name == "system.posix_acl_access" || name == "system.posix_acl_default" || name == "system.nfs4_acl"
}

// apply deliberately treats each selected metadata entry independently.  User xattrs are applied
// while the restoring identity still has owner-write permission; the final ordinary mode is then
// installed, and ACL xattrs are applied afterwards so chmod cannot rewrite their masks/semantics.
// mtime is always attempted last.  Strict mode is fail-closed.  Explicit degradation mode may skip
// unsupported/permission-denied/rejected metadata operations, but never payload/path/decoding or storage errors.
func apply(path, modeS, mtimeS, envB64 string, allowDegradation bool) ([]string, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, errors.New("metadata apply requires regular file")
	}

	originalMode := st.Mode().Perm()
	var desiredMode *os.FileMode
	if modeS != "" {
		m, err := strconv.ParseUint(modeS, 8, 32)
		if err != nil {
			return nil, fmt.Errorf("invalid mode: %w", err)
		}
		mm := os.FileMode(m)
		desiredMode = &mm
	}

	degraded := []string{}
	recordDegraded := func(op, name string, e error) bool {
		if allowDegradation && degradable(e) {
			degraded = append(degraded, op+":"+name)
			fmt.Fprintf(os.Stderr, "bric-file-metadata: DEGRADED path=%s metadata=%s:%s error=%v\n", path, op, name, e)
			return true
		}
		return false
	}

	var env envelope
	haveEnv := envB64 != ""
	current := []string{}
	if haveEnv {
		raw, err := base64.StdEncoding.DecodeString(envB64)
		if err != nil {
			return nil, fmt.Errorf("metadata base64: %w", err)
		}
		if err := json.Unmarshal(raw, &env); err != nil {
			return nil, err
		}
		if env.Version != 1 {
			return nil, fmt.Errorf("unsupported metadata envelope version %d", env.Version)
		}
		if env.Xattrs == nil {
			env.Xattrs = map[string]string{}
		}
		current, err = listXattrs(path)
		if err != nil {
			return nil, err
		}
		sort.Strings(current)
	}

	// Metadata operations on user.* may require write permission even though the restoring identity
	// owns the freshly-created file.  Do not install an archived read-only mode (e.g. 0444) before
	// those operations.  Temporarily add owner-write, then restore/install the final mode below.
	workMode := originalMode
	needTempWrite := false
	if haveEnv {
		for _, name := range current {
			if selected(name) {
				needTempWrite = true
				break
			}
		}
		if len(env.Xattrs) > 0 {
			needTempWrite = true
		}
	}
	if needTempWrite && workMode&0200 == 0 {
		workMode |= 0200
		if err := os.Chmod(path, workMode); err != nil {
			return degraded, fmt.Errorf("temporary owner-write chmod: %w", err)
		}
	}

	if haveEnv {
		// Remove selected metadata that is absent from the archive while the file is still writable.
		// Removal happens before the final chmod because removing an ACL can itself alter mode bits.
		for _, name := range current {
			if !selected(name) {
				continue
			}
			if _, ok := env.Xattrs[name]; ok {
				continue
			}
			if e := syscall.Removexattr(path, name); e != nil && e != syscall.ENODATA {
				if recordDegraded("remove", name, e) {
					continue
				}
				return degraded, fmt.Errorf("removexattr %s: %w", name, e)
			}
		}

		names := make([]string, 0, len(env.Xattrs))
		for name := range env.Xattrs {
			names = append(names, name)
		}
		sort.Strings(names)

		// user.* first, while owner-write is guaranteed.  chmod does not rewrite user.* values.
		for _, name := range names {
			if !selected(name) {
				return degraded, fmt.Errorf("refusing unapproved xattr namespace: %s", name)
			}
			if aclXattr(name) {
				continue
			}
			v, err := base64.StdEncoding.DecodeString(env.Xattrs[name])
			if err != nil {
				return degraded, fmt.Errorf("decode xattr %s: %w", name, err)
			}
			if e := syscall.Setxattr(path, name, v, 0); e != nil {
				if recordDegraded("set", name, e) {
					continue
				}
				return degraded, fmt.Errorf("setxattr %s: %w", name, e)
			}
		}

		// Install the final ordinary mode only after user.* metadata has been handled.
		finalMode := originalMode
		if desiredMode != nil {
			finalMode = *desiredMode
		}
		if err := os.Chmod(path, finalMode); err != nil {
			return degraded, err
		}

		// ACL metadata is authoritative after chmod.  Unsupported or denied ACL operations may be
		// explicitly degraded, but strict mode remains fail-closed.
		for _, name := range names {
			if !aclXattr(name) {
				continue
			}
			v, err := base64.StdEncoding.DecodeString(env.Xattrs[name])
			if err != nil {
				return degraded, fmt.Errorf("decode xattr %s: %w", name, err)
			}
			if e := syscall.Setxattr(path, name, v, 0); e != nil {
				if recordDegraded("set", name, e) {
					continue
				}
				return degraded, fmt.Errorf("setxattr %s: %w", name, e)
			}
		}
	} else if desiredMode != nil {
		if err := os.Chmod(path, *desiredMode); err != nil {
			return degraded, err
		}
	}

	if mtimeS != "" {
		sec, err := strconv.ParseInt(mtimeS, 10, 64)
		if err != nil {
			return degraded, fmt.Errorf("invalid mtime: %w", err)
		}
		st2, err := os.Stat(path)
		if err != nil {
			return degraded, err
		}
		at := st2.ModTime()
		if sys, ok := st2.Sys().(*syscall.Stat_t); ok {
			at = time.Unix(sys.Atim.Sec, sys.Atim.Nsec)
		}
		if err := os.Chtimes(path, at, time.Unix(sec, 0)); err != nil {
			return degraded, err
		}
	}
	return degraded, nil
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println(version)
		return
	}
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: bric-file-metadata capture PATH | apply PATH MODE MTIME METADATA_B64 [--allow-degradation]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "capture":
		if len(os.Args) != 3 {
			os.Exit(2)
		}
		if err := capture(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "bric-file-metadata:", err)
			os.Exit(1)
		}
	case "apply":
		allow := false
		if len(os.Args) == 7 && os.Args[6] == "--allow-degradation" {
			allow = true
		} else if len(os.Args) != 6 {
			os.Exit(2)
		}
		degraded, err := apply(os.Args[2], os.Args[3], os.Args[4], os.Args[5], allow)
		if err != nil {
			fmt.Fprintln(os.Stderr, "bric-file-metadata:", err)
			os.Exit(1)
		}
		if len(degraded) > 0 {
			fmt.Fprintf(os.Stderr, "bric-file-metadata: metadata degraded (%d metadata operation(s))\n", len(degraded))
			os.Exit(4)
		}
	default:
		os.Exit(2)
	}
}
