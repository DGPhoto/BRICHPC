package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"hash"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const version = "BRIC tar-stream 34-file-metadata"

type config struct {
	runID, project, owner, source, runState, runDir            string
	encPassFile, hmacKeyFile, gateCmd, publishCmd, allocateCmd string
	target, chunkStart                                         int64
	progressEvery                                              int64
	sparseMinHoleBytes                                         int64
	sparseMaxAllocatedPercent                                  int64
	sparseBatchTarget                                          int64
}

type counters struct {
	entries, regular, unsupported, plainBytes, chunks, cipherBytes int64
}

type sparsePending struct {
	name                          string
	size, mtime, dataBytes, holes int64
	outerSHA                      string
}

type cryptoWriter struct {
	f       *os.File
	sha     hash.Hash
	mac     hash.Hash
	block   cipher.Block
	mode    cipher.BlockMode
	pending []byte
	written int64
	closed  bool
}

func pbkdf2SHA256(password, salt []byte, iter, keyLen int) []byte {
	hLen := 32
	blocks := (keyLen + hLen - 1) / hLen
	out := make([]byte, 0, blocks*hLen)
	for block := 1; block <= blocks; block++ {
		mac := hmac.New(sha256.New, password)
		mac.Write(salt)
		mac.Write([]byte{byte(block >> 24), byte(block >> 16), byte(block >> 8), byte(block)})
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for i := 1; i < iter; i++ {
			mac = hmac.New(sha256.New, password)
			mac.Write(u)
			u = mac.Sum(nil)
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func newCryptoWriter(filename string, passphrase, hmacKey []byte) (*cryptoWriter, error) {
	f, err := os.OpenFile(filename, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	salt := make([]byte, 8)
	if _, err = io.ReadFull(rand.Reader, salt); err != nil {
		f.Close()
		return nil, err
	}
	derived := pbkdf2SHA256(passphrase, salt, 10000, 48)
	block, err := aes.NewCipher(derived[:32])
	if err != nil {
		f.Close()
		return nil, err
	}
	cw := &cryptoWriter{f: f, sha: sha256.New(), mac: hmac.New(sha256.New, hmacKey), block: block, mode: cipher.NewCBCEncrypter(block, derived[32:48])}
	if err := cw.writeCiphertext(append([]byte("Salted__"), salt...)); err != nil {
		f.Close()
		return nil, err
	}
	return cw, nil
}

func (w *cryptoWriter) writeCiphertext(p []byte) error {
	if _, err := w.f.Write(p); err != nil {
		return err
	}
	_, _ = w.sha.Write(p)
	_, _ = w.mac.Write(p)
	w.written += int64(len(p))
	return nil
}
func (w *cryptoWriter) Write(p []byte) (int, error) {
	if w.closed {
		return 0, errors.New("write after close")
	}
	orig := len(p)
	w.pending = append(w.pending, p...)
	n := len(w.pending) / aes.BlockSize * aes.BlockSize
	if n > 0 {
		enc := make([]byte, n)
		w.mode.CryptBlocks(enc, w.pending[:n])
		if err := w.writeCiphertext(enc); err != nil {
			return 0, err
		}
		copy(w.pending, w.pending[n:])
		w.pending = w.pending[:len(w.pending)-n]
	}
	return orig, nil
}
func (w *cryptoWriter) Close() error {
	if w.closed {
		return nil
	}
	w.closed = true
	pad := aes.BlockSize - len(w.pending)%aes.BlockSize
	final := append(append([]byte(nil), w.pending...), bytes.Repeat([]byte{byte(pad)}, pad)...)
	enc := make([]byte, len(final))
	w.mode.CryptBlocks(enc, final)
	if err := w.writeCiphertext(enc); err != nil {
		w.f.Close()
		return err
	}
	if err := w.f.Sync(); err != nil {
		w.f.Close()
		return err
	}
	return w.f.Close()
}
func (w *cryptoWriter) SHA() string  { return hex.EncodeToString(w.sha.Sum(nil)) }
func (w *cryptoWriter) HMAC() string { return hex.EncodeToString(w.mac.Sum(nil)) }
func (w *cryptoWriter) Size() int64  { return w.written }

type hashReader struct {
	r io.Reader
	h hash.Hash
	n int64
}

func (r *hashReader) Read(p []byte) (int, error) {
	n, e := r.r.Read(p)
	if n > 0 {
		_, _ = r.h.Write(p[:n])
		r.n += int64(n)
	}
	return n, e
}

type chunk struct {
	cfg                               *config
	no                                int64
	kind                              string
	plain                             int64
	memberIndex                       int64
	manifestPath, partPath, finalPath string
	manifest                          *os.File
	manifestBuf                       *bufio.Writer
	enc                               *cryptoWriter
	tw                                *tar.Writer
}

func sqlQuote(s string) string { return strings.ReplaceAll(s, "'", "''") }
func normalizeName(n string) (string, error) {
	n = strings.TrimPrefix(n, "./")
	if n == "" || n == "." {
		return "", nil
	}
	if strings.IndexByte(n, 0) >= 0 {
		return "", errors.New("NUL in tar member")
	}
	c := path.Clean(n)
	if c == "." {
		return "", nil
	}
	if path.IsAbs(c) || c == ".." || strings.HasPrefix(c, "../") {
		return "", fmt.Errorf("unsafe tar member %q", n)
	}
	return c, nil
}
func tarFootprint(h *tar.Header) int64 {
	d := ((h.Size + 511) / 512) * 512
	extra := int64(512)
	if len(h.Name) > 90 || len(h.Linkname) > 90 || len(h.PAXRecords) > 0 {
		extra += 4096
	}
	return extra + d
}
func cloneHeader(h *tar.Header) *tar.Header {
	c := *h
	if h.PAXRecords != nil {
		c.PAXRecords = make(map[string]string, len(h.PAXRecords))
		for k, v := range h.PAXRecords {
			c.PAXRecords[k] = v
		}
	}
	if h.Xattrs != nil {
		c.Xattrs = make(map[string]string, len(h.Xattrs))
		for k, v := range h.Xattrs {
			c.Xattrs[k] = v
		}
	}
	return &c
}
func pathDepth(n string) int { return strings.Count(strings.Trim(n, "/"), "/") }
func readSecret(p string) ([]byte, error) {
	b, e := os.ReadFile(p)
	if e != nil {
		return nil, e
	}
	return bytes.TrimSpace(b), nil
}
func runCommand(name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Stdout = os.Stderr
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		return fmt.Errorf("command %s %q failed: %w", name, args, err)
	}
	return nil
}
func runCommandOutput(name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	var out bytes.Buffer
	c.Stdout = &out
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		return "", fmt.Errorf("command %s %q failed: %w", name, args, err)
	}
	return strings.TrimSpace(out.String()), nil
}

func captureFileMetadata(source, name string) (string, string, string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", "", "", err
	}
	helper := filepath.Join(filepath.Dir(exe), "bric-file-metadata")
	out, err := runCommandOutput(helper, "capture", filepath.Join(source, filepath.FromSlash(name)))
	if err != nil {
		return "", "", "", err
	}
	parts := strings.Split(out, "\t")
	if len(parts) != 3 {
		return "", "", "", fmt.Errorf("invalid metadata helper output for %q", name)
	}
	return parts[0], parts[1], parts[2], nil
}

func writeProgress(cfg *config, c counters, stage string) error {
	p := filepath.Join(cfg.runState, "progress")
	tmp := p + ".tmp." + strconv.Itoa(os.Getpid())
	data := fmt.Sprintf("stage=%s\nfiles=%d\nbytes=%d\nchunks=%d\nupdated=%s\n", stage, c.entries, c.plainBytes, c.chunks, time.Now().UTC().Format(time.RFC3339))
	if err := os.WriteFile(tmp, []byte(data), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}
func newChunkMode(cfg *config, c *counters, kind string, raw bool, encPass, hmacKey []byte) (*chunk, error) {
	no := cfg.chunkStart + c.chunks
	if cfg.allocateCmd != "" {
		// Parallel workers must serialize capacity accounting with chunk-number allocation. The allocator
		// counts every already-published byte plus every ALLOCATED in-progress chunk at one full target,
		// extends the tape reservation if needed, then reserves a unique chunk number under one lock.
		out, err := runCommandOutput(cfg.allocateCmd, "--run", cfg.runID, "--type", kind, "--gate", cfg.gateCmd, "--target", strconv.FormatInt(cfg.target, 10))
		if err != nil {
			return nil, err
		}
		allocated, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
		if err != nil || allocated <= 0 {
			return nil, fmt.Errorf("allocator returned invalid chunk number %q", out)
		}
		no = allocated
	} else {
		// Sequential producer: its local ciphertext total is also the run total.
		required := c.cipherBytes + cfg.target + cfg.target/20
		if err := runCommand(cfg.gateCmd, "--run", cfg.runID, "--required-total", strconv.FormatInt(required, 10)); err != nil {
			return nil, err
		}
	}
	base := filepath.Join(cfg.runDir, fmt.Sprintf("chunk_%04d", no))
	part := base + ".enc.part"
	final := base + ".enc"
	_ = os.Remove(part)
	enc, err := newCryptoWriter(part, encPass, hmacKey)
	if err != nil {
		return nil, err
	}
	mfpath := filepath.Join(cfg.runState, fmt.Sprintf("chunk_%04d.files.sql", no))
	mf, err := os.OpenFile(mfpath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		enc.Close()
		return nil, err
	}
	ch := &chunk{cfg: cfg, no: no, kind: kind, manifestPath: mfpath, partPath: part, finalPath: final, manifest: mf, manifestBuf: bufio.NewWriterSize(mf, 1<<20), enc: enc}
	if kind == "TAR_PART" && !raw {
		ch.tw = tar.NewWriter(enc)
	}
	return ch, nil
}
func newChunk(cfg *config, c *counters, kind string, encPass, hmacKey []byte) (*chunk, error) {
	return newChunkMode(cfg, c, kind, false, encPass, hmacKey)
}
func newRawTarChunk(cfg *config, c *counters, encPass, hmacKey []byte) (*chunk, error) {
	return newChunkMode(cfg, c, "TAR_PART", true, encPass, hmacKey)
}
func hasGNUSparse(h *tar.Header) bool {
	if h.Typeflag == tar.TypeGNUSparse {
		return true
	}
	for k := range h.PAXRecords {
		if strings.HasPrefix(k, "GNU.sparse.") {
			return true
		}
	}
	return false
}
func regularizeSparseHeader(h *tar.Header) *tar.Header {
	c := cloneHeader(h)
	c.Typeflag = tar.TypeReg
	for k := range c.PAXRecords {
		if strings.HasPrefix(k, "GNU.sparse.") {
			delete(c.PAXRecords, k)
		}
	}
	if len(c.PAXRecords) == 0 {
		c.PAXRecords = nil
	}
	return c
}
func sparseMapUsage(h *tar.Header) (dataBytes, holes int64, err error) {
	// Review 31B deliberately derives sparse economics from the GNU PAX sparse map already present in
	// the authoritative outer tar stream.  st_blocks is NOT an extent map on remote/data-reduced filesystems
	// (notably OneFS over NFSv3), and SEEK_HOLE may degrade to the generic "hole at EOF" answer there.
	// GNU.sparse.map describes the data ranges GNU tar actually chose for this member, which is exactly
	// what matters for deciding whether preserving that representation is worth a separate sparse batch.
	raw, ok := h.PAXRecords["GNU.sparse.map"]
	if !ok || strings.TrimSpace(raw) == "" {
		return 0, 0, fmt.Errorf("GNU sparse member has no GNU.sparse.map")
	}
	parts := strings.Split(raw, ",")
	if len(parts)%2 != 0 {
		return 0, 0, fmt.Errorf("malformed GNU.sparse.map with %d fields", len(parts))
	}
	var prevEnd int64
	for i := 0; i < len(parts); i += 2 {
		off, e1 := strconv.ParseInt(strings.TrimSpace(parts[i]), 10, 64)
		ln, e2 := strconv.ParseInt(strings.TrimSpace(parts[i+1]), 10, 64)
		if e1 != nil || e2 != nil || off < 0 || ln < 0 {
			return 0, 0, fmt.Errorf("invalid GNU sparse extent %q,%q", parts[i], parts[i+1])
		}
		if off < prevEnd || off > h.Size || ln > h.Size-off {
			return 0, 0, fmt.Errorf("out-of-range/overlapping GNU sparse extent %d,%d for logical size %d", off, ln, h.Size)
		}
		dataBytes += ln
		prevEnd = off + ln
	}
	if dataBytes > h.Size {
		return 0, 0, fmt.Errorf("GNU sparse data bytes %d exceed logical size %d", dataBytes, h.Size)
	}
	return dataBytes, h.Size - dataBytes, nil
}
func meaningfulSparse(cfg *config, h *tar.Header) (bool, int64, int64, error) {
	dataBytes, holes, err := sparseMapUsage(h)
	if err != nil {
		return false, 0, 0, err
	}
	meaningful := holes >= cfg.sparseMinHoleBytes
	if !meaningful && h.Size > 0 {
		threshold := (h.Size/100)*cfg.sparseMaxAllocatedPercent + ((h.Size%100)*cfg.sparseMaxAllocatedPercent)/100
		meaningful = dataBytes <= threshold
	}
	return meaningful, dataBytes, holes, nil
}
func sparseBatchEstimate(dataBytes int64) int64 {
	// The PAX map gives the data ranges GNU tar selected, so unlike st_blocks this estimate remains
	// meaningful on compressed/deduplicated/NFS-backed sources.  Add conservative tar metadata overhead.
	const overhead = int64(64 * 1024)
	if dataBytes < 0 {
		dataBytes = 0
	}
	return dataBytes + overhead
}

func writeSparseTarBatch(cfg *config, ch *chunk, pending []sparsePending) error {
	if len(pending) == 0 {
		return nil
	}
	cmd := exec.Command("tar", "--create", "--file=-", "--format=pax", "--hard-dereference", "--acls", "--xattrs", "--xattrs-include=user.*", "--xattrs-include=system.nfs4_acl",
		"--mode=u-s,g-s,o-t", "--sparse", "--sparse-version=0.1", "--no-recursion", "--null", "--verbatim-files-from",
		"-C", cfg.source, "--files-from=-")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return err
	}

	// Feed the potentially large NUL-delimited list concurrently with consuming tar stdout so neither
	// pipe can deadlock.  Verification is performed on the exact tar bytes being encrypted: TeeReader
	// sends raw GNU tar output to ch.enc while archive/tar exposes each logical member for hashing.
	writeCh := make(chan error, 1)
	go func() {
		var werr error
		for _, sp := range pending {
			if werr == nil {
				_, werr = io.WriteString(stdin, sp.name+"\x00")
			}
		}
		if cerr := stdin.Close(); werr == nil {
			werr = cerr
		}
		writeCh <- werr
	}()

	tee := io.TeeReader(bufio.NewReaderSize(stdout, 4<<20), ch.enc)
	tr := tar.NewReader(tee)
	var verifyErr error
	seen := 0
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			verifyErr = fmt.Errorf("read generated sparse TAR_PART: %w", e)
			break
		}
		idx := seen
		seen++
		hashv := sha256.New()
		hr := &hashReader{r: tr, h: hashv}
		_, copyErr := io.CopyBuffer(io.Discard, hr, make([]byte, 4<<20))
		if copyErr != nil && verifyErr == nil {
			verifyErr = fmt.Errorf("hash generated sparse member %q: %w", h.Name, copyErr)
		}
		if idx >= len(pending) {
			if verifyErr == nil {
				verifyErr = fmt.Errorf("generated sparse TAR_PART has unexpected extra member %q", h.Name)
			}
			continue
		}
		name, nameErr := normalizeName(h.Name)
		if nameErr != nil && verifyErr == nil {
			verifyErr = nameErr
		}
		sp := pending[idx]
		gotSHA := hex.EncodeToString(hashv.Sum(nil))
		if verifyErr == nil && (name != sp.name || h.Size != sp.size || hr.n != sp.size || gotSHA != sp.outerSHA) {
			verifyErr = fmt.Errorf("sparse file %q changed between authoritative walk and batched TAR_PART (generated name=%q size=%d/%d bytes=%d sha_match=%t)", sp.name, name, h.Size, sp.size, hr.n, gotSHA == sp.outerSHA)
		}
	}
	// archive/tar stops at the logical end of archive. Preserve any GNU tar record padding too, so the
	// encrypted payload is byte-for-byte a complete GNU tar stream even though the verifier is finished.
	if _, e := io.CopyBuffer(ch.enc, stdout, make([]byte, 4<<20)); e != nil && verifyErr == nil {
		verifyErr = fmt.Errorf("drain generated sparse TAR_PART: %w", e)
	}
	writeErr := <-writeCh
	waitErr := cmd.Wait()
	if writeErr != nil {
		return fmt.Errorf("write GNU tar sparse file list: %w", writeErr)
	}
	if waitErr != nil {
		return fmt.Errorf("GNU tar sparse batch (%d members) failed: %w", len(pending), waitErr)
	}
	if seen != len(pending) && verifyErr == nil {
		verifyErr = fmt.Errorf("generated sparse TAR_PART member count mismatch: got %d expected %d", seen, len(pending))
	}
	if verifyErr != nil {
		return verifyErr
	}
	return nil
}

func flushSparseBatch(cfg *config, c *counters, pending *[]sparsePending, pendingEstimate *int64, encPass, hmacKey []byte) error {
	if len(*pending) == 0 {
		return nil
	}
	batch := *pending
	est := *pendingEstimate
	ch, err := newRawTarChunk(cfg, c, encPass, hmacKey)
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = ch.manifest.Close()
			_ = ch.enc.f.Close()
			_ = os.Remove(ch.partPath)
			_ = os.Remove(ch.manifestPath)
		}
	}()
	if err = writeSparseTarBatch(cfg, ch, batch); err != nil {
		return err
	}
	var logical int64
	for i, sp := range batch {
		// writeSparseTarBatch already hashed the exact logical member bytes from the generated tar stream
		// while those same raw bytes were encrypted.  The outer-stream hash is therefore safe to catalog
		// without a third source read.
		rec := fmt.Sprintf("INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES('%s','%s',%d,%d,'%s',%d,%d,'F');", sqlQuote(cfg.runID), sqlQuote(sp.name), sp.size, sp.mtime, sp.outerSHA, ch.no, i)
		if err = ch.addSQL(rec); err != nil {
			return err
		}
		logical += sp.size
	}
	c.plainBytes += logical
	ch.plain = est
	if err = ch.close(c, "", 0, 0, 0); err != nil {
		return err
	}
	committed = true
	fmt.Fprintf(os.Stderr, "bric-tar-stream: preserved %d sparse file(s) in batched TAR_PART chunk %d (logical=%d sparse_map_payload_estimate=%d ciphertext=%d)\n", len(batch), ch.no, logical, est, ch.enc.Size())
	*pending = nil
	*pendingEstimate = 0
	return nil
}
func (ch *chunk) addSQL(rec string) error { _, e := ch.manifestBuf.WriteString(rec + "\n"); return e }
func (ch *chunk) close(c *counters, bigPath string, idx, total int64, offset int64) error {
	if ch.tw != nil {
		if err := ch.tw.Close(); err != nil {
			return err
		}
	}
	if err := ch.manifestBuf.Flush(); err != nil {
		return err
	}
	if err := ch.manifest.Close(); err != nil {
		return err
	}
	if err := ch.enc.Close(); err != nil {
		return err
	}
	if err := os.Rename(ch.partPath, ch.finalPath); err != nil {
		return err
	}
	args := []string{"--run", ch.cfg.runID, "--chunk", strconv.FormatInt(ch.no, 10), "--type", ch.kind, "--size", strconv.FormatInt(ch.enc.Size(), 10), "--sha", ch.enc.SHA(), "--hmac", ch.enc.HMAC(), "--manifest", ch.manifestPath, "--plain-total", strconv.FormatInt(c.plainBytes, 10), "--files-total", strconv.FormatInt(c.entries, 10)}
	if bigPath != "" {
		args = append(args, "--big-rel", bigPath, "--chunk-index", strconv.FormatInt(idx, 10), "--total-chunks", strconv.FormatInt(total, 10), "--offset", strconv.FormatInt(offset, 10))
	}
	if err := runCommand(ch.cfg.publishCmd, args...); err != nil {
		return err
	}
	c.chunks++
	c.cipherBytes += ch.enc.Size()
	_ = os.Remove(ch.manifestPath)
	return writeProgress(ch.cfg, *c, "archiving")
}

func main() {
	var cfg config
	var showVersion bool
	flag.StringVar(&cfg.runID, "run", "", "run id")
	flag.StringVar(&cfg.project, "project", "", "project")
	flag.StringVar(&cfg.owner, "owner", "", "owner")
	flag.StringVar(&cfg.source, "source", "", "source")
	flag.StringVar(&cfg.runState, "runstate", "", "runstate dir")
	flag.StringVar(&cfg.runDir, "run-dir", "", "qnap run dir")
	flag.StringVar(&cfg.encPassFile, "enc-pass-file", "", "encryption pass file")
	flag.StringVar(&cfg.hmacKeyFile, "hmac-key-file", "", "hmac key file")
	flag.StringVar(&cfg.gateCmd, "gate", "", "gate command")
	flag.StringVar(&cfg.publishCmd, "publish", "", "publish command")
	flag.StringVar(&cfg.allocateCmd, "allocate", "", "optional atomic chunk-number allocator for parallel producers")
	flag.Int64Var(&cfg.target, "target", 128000000000, "plaintext chunk target")
	flag.Int64Var(&cfg.chunkStart, "chunk-start", 1, "first chunk number when no parallel allocator is used")
	flag.Int64Var(&cfg.progressEvery, "progress-every", 5000, "progress interval")
	flag.Int64Var(&cfg.sparseMinHoleBytes, "sparse-min-hole", 67108864, "minimum GNU PAX sparse-map hole bytes that justify batched sparse TAR_PART")
	flag.Int64Var(&cfg.sparseMaxAllocatedPercent, "sparse-max-allocated-percent", 75, "preserve GNU PAX sparse representation when mapped data bytes are at most this percent of logical size")
	flag.Int64Var(&cfg.sparseBatchTarget, "sparse-batch-target", 4294967296, "estimated sparse TAR_PART batch target bytes")
	flag.BoolVar(&showVersion, "version", false, "show version")
	flag.Parse()
	if showVersion {
		fmt.Println(version)
		return
	}
	if cfg.runID == "" || cfg.project == "" || cfg.owner == "" || cfg.runState == "" || cfg.runDir == "" || cfg.gateCmd == "" || cfg.publishCmd == "" {
		fmt.Fprintln(os.Stderr, "missing required arguments")
		os.Exit(2)
	}
	if cfg.chunkStart <= 0 {
		fmt.Fprintln(os.Stderr, "invalid chunk-start")
		os.Exit(2)
	}
	if cfg.sparseMinHoleBytes < 0 || cfg.sparseMaxAllocatedPercent < 0 || cfg.sparseMaxAllocatedPercent > 100 || cfg.sparseBatchTarget <= 0 {
		fmt.Fprintln(os.Stderr, "invalid sparse policy")
		os.Exit(2)
	}
	encPass, err := readSecret(cfg.encPassFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	hmacKey, err := readSecret(cfg.hmacKeyFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.runState, 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.runDir, 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	outerIn := bufio.NewReaderSize(os.Stdin, 4<<20)
	tr := tar.NewReader(outerIn)
	var cur *chunk
	var dirs []*tar.Header
	var sparsePendingFiles []sparsePending
	var sparsePendingEstimate int64
	var c counters
	defer func() {
		if cur != nil {
			_ = cur.manifestBuf.Flush()
			_ = cur.manifest.Close()
			_ = cur.enc.f.Close()
			_ = os.Remove(cur.partPath)
			_ = os.Remove(cur.manifestPath)
		}
	}()
	fail := func(e error) { fmt.Fprintf(os.Stderr, "bric-tar-stream: %v\n", e); os.Exit(1) }
	_ = writeProgress(&cfg, c, "archiving")
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			fail(e)
		}
		name, e := normalizeName(h.Name)
		if e != nil {
			fail(e)
		}
		if name == "" {
			continue
		}
		h.Name = name
		switch h.Typeflag {
		case tar.TypeReg, tar.TypeRegA, tar.TypeGNUSparse:
			c.entries++
			c.regular++
			if hasGNUSparse(h) {
				preserve, dataBytes, holes, mapErr := meaningfulSparse(&cfg, h)
				if mapErr != nil {
					fail(fmt.Errorf("cannot interpret GNU sparse map for %q: %w", name, mapErr))
				}
				if preserve {
					// Preserve sparse allocation, but do not equate one sparse member with one tape chunk.
					// Consume/hash the authoritative outer stream now, queue metadata only, and later ask one
					// GNU tar process to emit many sparse members into a single valid TAR_PART.
					outerHash := sha256.New()
					hr := &hashReader{r: tr, h: outerHash}
					if _, e = io.CopyBuffer(io.Discard, hr, make([]byte, 4<<20)); e != nil {
						fail(e)
					}
					if hr.n != h.Size {
						fail(fmt.Errorf("short sparse read for %s: %d/%d", name, hr.n, h.Size))
					}
					sparsePendingFiles = append(sparsePendingFiles, sparsePending{name: name, size: h.Size, mtime: h.ModTime.Unix(), dataBytes: dataBytes, holes: holes, outerSHA: hex.EncodeToString(outerHash.Sum(nil))})
					sparsePendingEstimate += sparseBatchEstimate(dataBytes)
					fmt.Fprintf(os.Stderr, "bric-tar-stream: queued sparse file %q for TAR_PART batch (logical=%d sparse_map_data=%d holes=%d batch_estimate=%d/%d)\n", name, h.Size, dataBytes, holes, sparsePendingEstimate, cfg.sparseBatchTarget)
					if sparsePendingEstimate >= cfg.sparseBatchTarget {
						if cur != nil {
							if e := cur.close(&c, "", 0, 0, 0); e != nil {
								fail(e)
							}
							cur = nil
						}
						if e := flushSparseBatch(&cfg, &c, &sparsePendingFiles, &sparsePendingEstimate, encPass, hmacKey); e != nil {
							fail(e)
						}
					}
					continue
				}

				// Small alignment holes are common in ELF/shared-library files. Keeping every such file
				// as its own tape file destroys throughput. Materialize only those small holes and let the
				// member join the normal TAR_PART stream; content and logical size remain exact.
				fmt.Fprintf(os.Stderr, "bric-tar-stream: normalized lightly sparse file %q into regular TAR_PART (logical=%d sparse_map_data=%d holes=%d)\n", name, h.Size, dataBytes, holes)
				h = regularizeSparseHeader(h)
			}
			if h.Size > cfg.target {
				if cur != nil {
					if e := cur.close(&c, "", 0, 0, 0); e != nil {
						fail(e)
					}
					cur = nil
				}
				if len(sparsePendingFiles) > 0 {
					if e := flushSparseBatch(&cfg, &c, &sparsePendingFiles, &sparsePendingEstimate, encPass, hmacKey); e != nil {
						fail(e)
					}
				}
				modeBefore, mtimeBefore, metaBefore, e := captureFileMetadata(cfg.source, name)
				if e != nil {
					fail(fmt.Errorf("capture metadata for %s: %w", name, e))
				}
				if strconv.FormatInt(h.Mode&0777, 8) != strings.TrimLeft(modeBefore, "0") && !(h.Mode&0777 == 0 && modeBefore == "0000") {
					fail(fmt.Errorf("mode changed between tar header and large-file capture for %s", name))
				}
				total := (h.Size + cfg.target - 1) / cfg.target
				idx := int64(1)
				off := int64(0)
				firstChunkNo := int64(0)
				fh := sha256.New()
				remaining := h.Size
				for remaining > 0 {
					piece := cfg.target
					if remaining < piece {
						piece = remaining
					}
					ch, e := newChunk(&cfg, &c, "LARGE_FILE_CHUNK", encPass, hmacKey)
					if e != nil {
						fail(e)
					}
					if firstChunkNo == 0 {
						firstChunkNo = ch.no
					}
					hr := &hashReader{r: io.LimitReader(tr, piece), h: fh}
					if _, e = io.CopyBuffer(ch.enc, hr, make([]byte, 4<<20)); e != nil {
						fail(e)
					}
					if hr.n != piece {
						fail(fmt.Errorf("short read for %s piece %d: %d/%d", name, idx, hr.n, piece))
					}
					c.plainBytes += piece
					ch.plain = piece
					if e = ch.close(&c, name, idx, total, off); e != nil {
						fail(e)
					}
					remaining -= piece
					off += piece
					idx++
				}
				sha := hex.EncodeToString(fh.Sum(nil))
				modeAfter, mtimeAfter, metaAfter, e := captureFileMetadata(cfg.source, name)
				if e != nil {
					fail(fmt.Errorf("recapture metadata for %s: %w", name, e))
				}
				if modeBefore != modeAfter || mtimeBefore != mtimeAfter || metaBefore != metaAfter {
					fail(fmt.Errorf("metadata changed during large-file read for %s", name))
				}
				if e := runCommand(cfg.publishCmd, "--run", cfg.runID, "--file-finalize", name, "--file-size", strconv.FormatInt(h.Size, 10), "--file-mtime", mtimeBefore, "--file-mode", modeBefore, "--file-metadata-b64", metaBefore, "--file-sha", sha, "--first-chunk", strconv.FormatInt(firstChunkNo, 10)); e != nil {
					fail(e)
				}
			} else {
				need := tarFootprint(h) + 1024
				if cur != nil && cur.plain > 0 && cur.plain+need > cfg.target {
					if e := cur.close(&c, "", 0, 0, 0); e != nil {
						fail(e)
					}
					cur = nil
				}
				if cur == nil {
					cur, e = newChunk(&cfg, &c, "TAR_PART", encPass, hmacKey)
					if e != nil {
						fail(e)
					}
				}
				fh := sha256.New()
				hr := &hashReader{r: tr, h: fh}
				// Security policy: regular-file setuid/setgid/sticky bits are deliberately not archived.
				// Ownership is not restored (--no-same-owner), so resurrecting those bits could change meaning.
				h.Mode &= 0777
				if e = cur.tw.WriteHeader(h); e != nil {
					fail(e)
				}
				if _, e = io.CopyBuffer(cur.tw, hr, make([]byte, 4<<20)); e != nil {
					fail(e)
				}
				if hr.n != h.Size {
					fail(fmt.Errorf("short read for %s: %d/%d", name, hr.n, h.Size))
				}
				sha := hex.EncodeToString(fh.Sum(nil))
				cur.plain += need
				c.plainBytes += h.Size
				rec := fmt.Sprintf("INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES('%s','%s',%d,%d,'%s',%d,%d,'F');", sqlQuote(cfg.runID), sqlQuote(name), h.Size, h.ModTime.Unix(), sha, cur.no, cur.memberIndex)
				if e = cur.addSQL(rec); e != nil {
					fail(e)
				}
				cur.memberIndex++
			}
		case tar.TypeDir:
			// Directory ownership/mode/mtime must be applied only after every regular and oversized file
			// has been restored.  Otherwise a read-only directory emitted before a LARGE_FILE_CHUNK makes
			// unprivileged recovery fail with EACCES.  Keep only the small headers in memory and emit them
			// as final metadata TAR_PART chunks, deepest paths first and parents last.
			c.entries++
			dirs = append(dirs, cloneHeader(h))
		case tar.TypeSymlink:
			c.entries++
			need := tarFootprint(h) + 1024
			if cur != nil && cur.plain > 0 && cur.plain+need > cfg.target {
				if e := cur.close(&c, "", 0, 0, 0); e != nil {
					fail(e)
				}
				cur = nil
			}
			if cur == nil {
				cur, e = newChunk(&cfg, &c, "TAR_PART", encPass, hmacKey)
				if e != nil {
					fail(e)
				}
			}
			if e = cur.tw.WriteHeader(h); e != nil {
				fail(e)
			}
			cur.plain += need
			rec := fmt.Sprintf("INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES('%s','%s',0,%d,'',%d,%d,'L');", sqlQuote(cfg.runID), sqlQuote(name), h.ModTime.Unix(), cur.no, cur.memberIndex)
			if e = cur.addSQL(rec); e != nil {
				fail(e)
			}
			cur.memberIndex++
		default:
			c.entries++
			c.unsupported++
			fmt.Fprintf(os.Stderr, "warning: skipped unsupported tar member %q type=%d\n", name, h.Typeflag)
		}
		if cfg.progressEvery > 0 && c.entries%cfg.progressEvery == 0 {
			_ = writeProgress(&cfg, c, "archiving")
			fmt.Fprintf(os.Stderr, "[%s] archive progress: %d entries, %.2f TiB, %d completed chunk(s)\n", time.Now().Format("2006-01-02 15:04:05"), c.entries, float64(c.plainBytes)/1099511627776.0, c.chunks)
		}
	}
	// archive/tar stops as soon as it sees the logical end-of-archive (two zero blocks). GNU tar may
	// still be writing zero-filled record padding, especially with Review 32A's larger outer record.
	// Drain that padding to EOF so the producer never receives SIGPIPE. Reject any non-zero trailing
	// bytes: this keeps concatenated/garbled input from being silently ignored.
	pad := make([]byte, 4<<20)
	for {
		n, e := outerIn.Read(pad)
		for _, b := range pad[:n] {
			if b != 0 {
				fail(errors.New("non-zero data after logical end of outer tar archive"))
			}
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			fail(fmt.Errorf("drain outer tar record padding: %w", e))
		}
	}
	if cur != nil {
		if e := cur.close(&c, "", 0, 0, 0); e != nil {
			fail(e)
		}
		cur = nil
	}
	if len(sparsePendingFiles) > 0 {
		if e := flushSparseBatch(&cfg, &c, &sparsePendingFiles, &sparsePendingEstimate, encPass, hmacKey); e != nil {
			fail(e)
		}
	}
	// Final metadata chunks: deepest directories first, parents last.  Combined with GNU tar's
	// --delay-directory-restore this preserves restrictive modes without blocking later extraction.
	sort.SliceStable(dirs, func(i, j int) bool {
		di, dj := pathDepth(dirs[i].Name), pathDepth(dirs[j].Name)
		if di != dj {
			return di > dj
		}
		return dirs[i].Name > dirs[j].Name
	})
	for _, dh := range dirs {
		need := tarFootprint(dh) + 1024
		if cur != nil && cur.plain > 0 && cur.plain+need > cfg.target {
			if e := cur.close(&c, "", 0, 0, 0); e != nil {
				fail(e)
			}
			cur = nil
		}
		if cur == nil {
			cur, err = newChunk(&cfg, &c, "TAR_PART", encPass, hmacKey)
			if err != nil {
				fail(err)
			}
		}
		if err = cur.tw.WriteHeader(dh); err != nil {
			fail(err)
		}
		cur.plain += need
		rec := fmt.Sprintf("INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES('%s','%s',0,%d,'',%d,%d,'D');", sqlQuote(cfg.runID), sqlQuote(dh.Name), dh.ModTime.Unix(), cur.no, cur.memberIndex)
		if err = cur.addSQL(rec); err != nil {
			fail(err)
		}
		cur.memberIndex++
	}
	if cur != nil {
		if e := cur.close(&c, "", 0, 0, 0); e != nil {
			fail(e)
		}
		cur = nil
	}
	if c.unsupported > 0 {
		fmt.Fprintf(os.Stderr, "warning: skipped %d unsupported special tar member(s)\n", c.unsupported)
	}
	if c.chunks == 0 {
		fail(errors.New("source produced no archivable entries"))
	}
	if e := writeProgress(&cfg, c, "produced"); e != nil {
		fail(e)
	}
	fmt.Printf("chunks=%d\nentries=%d\nbytes=%d\ncipher_bytes=%d\n", c.chunks, c.entries, c.plainBytes, c.cipherBytes)
}
