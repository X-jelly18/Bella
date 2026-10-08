// Command ayanakoji_proxy accepts tunnel clients and relays them to a local SSH
// server, completing whatever handshake the client expects first.
//
// Each port is configured independently with -listen PORTS:MODE[:tls]:
//
//	direct   no handshake, relay the stream straight away
//	connect  HTTP CONNECT, reply "HTTP/1.1 200 Connection established"
//	payload  read the client's request head, reply a configurable status line
//	auto     sniff the first bytes and pick connect, direct or payload
//
// Appending @ssh, @ovpn or @auto picks the backend the tunnel is handed to, so
// a handshake mode OpenVPN cannot speak for itself still reaches an OpenVPN
// server. @auto reads the first bytes of the tunnelled stream and routes SSH
// and OpenVPN clients on one port.
//
// Appending :tls terminates TLS on that port, and the handshake above then
// happens inside the TLS session. That composition is what tunnel clients call
// "SSL + payload" or "SSL + proxy":
//
//	ayanakoji_proxy -listen 443:direct:tls -listen 8443:auto:tls \
//	    -listen 8888:connect -listen 2053:payload \
//	    -cert cert.pem -key key.pem
//
// A bare port list (-listen 443) means direct over TLS, so units written for
// the TLS-only version keep working.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultPayloadStatus = "200 <font color='red'>@Official_Kiyotaka</font>"
	defaultConnectStatus = "200 <font color='red'>@Official_Kiyotaka</font>"
)

const (
	// Relay buffer, and the bufio reader size, so a request head up to
	// maxHeaderBytes always fits without the reader reporting ErrBufferFull.
	relayBufferSize = 16 << 10

	// Bounds on the client handshake. Without these a peer can hold a
	// connection open while the server buffers an unbounded request head.
	maxHeaderBytes = 8 << 10
	maxHeaderLines = 100
)

type mode string

const (
	modeDirect  mode = "direct"
	modeConnect mode = "connect"
	modePayload mode = "payload"
	modeAuto    mode = "auto"
)

// target names the backend a listener hands its tunnels to.
type target string

const (
	targetSSH  target = "ssh"
	targetOVPN target = "ovpn"
	targetAuto target = "auto"
)

// How long a client on an @auto port has to reveal which protocol it speaks.
// Both OpenVPN and OpenSSH clients send first, so this only bites a client that
// stays silent, which then falls back to SSH.
const targetSniffTimeout = 1500 * time.Millisecond

type listener struct {
	port   string
	mode   mode
	useTLS bool
	target target
}

func (l listener) String() string {
	if l.useTLS {
		return fmt.Sprintf(":%s %s over tls -> %s", l.port, l.mode, l.target)
	}
	return fmt.Sprintf(":%s %s -> %s", l.port, l.mode, l.target)
}

type config struct {
	sshBackend       string
	ovpnBackend      string
	connectTimeout   time.Duration
	handshakeTimeout time.Duration
	payloadResponse  []byte
	connectResponse  []byte
	payloadMatch     string
	paths            []string
	extraHeads       int
}

type repeatedFlag []string

func (f *repeatedFlag) String() string { return strings.Join(*f, " ") }

func (f *repeatedFlag) Set(v string) error {
	*f = append(*f, v)
	return nil
}

func main() {
	log.SetFlags(log.LstdFlags)

	var listenArgs repeatedFlag
	flag.Var(&listenArgs, "listen", "PORTS:MODE[:tls][@ssh|@ovpn|@auto], repeatable (default 443:direct:tls@ssh)")

	hostArg := flag.String("host", "0.0.0.0", "Address to bind")
	certArg := flag.String("cert", "", "TLS certificate chain, required by any :tls listener")
	keyArg := flag.String("key", "", "TLS private key, required by any :tls listener")
	sshHostArg := flag.String("ssh-host", "127.0.0.1", "Upstream SSH host")
	sshPortArg := flag.String("ssh-port", "22", "Upstream SSH port")
	ovpnHostArg := flag.String("ovpn-host", "127.0.0.1", "Upstream OpenVPN host")
	ovpnPortArg := flag.String("ovpn-port", "1194", "Upstream OpenVPN port (must be a TCP listener)")
	connTimeoutArg := flag.Int("connect-timeout-secs", 5, "Seconds to wait for the SSH backend")
	handshakeTimeoutArg := flag.Int("handshake-timeout-secs", 10, "Seconds a client has to finish its handshake")
	maxConnsArg := flag.Int("max-conns", 0, "Maximum concurrent tunnels (0 = unlimited)")
	shutdownGraceArg := flag.Int("shutdown-grace-secs", 10, "Seconds to let tunnels drain on SIGTERM")

	payloadStatusArg := flag.String("payload-status", defaultPayloadStatus,
		"Status line returned to payload clients (empty = reply with nothing)")
	connectStatusArg := flag.String("connect-status", defaultConnectStatus,
		"Status line returned to HTTP CONNECT clients")
	payloadMatchArg := flag.String("payload-match", "",
		"If set, a payload client's request head must contain this substring")
	extraHeadsArg := flag.Int("payload-extra-heads", 0,
		"Extra request heads to consume after the first, for clients that send a split payload")
	pathArg := flag.String("path", "",
		"Comma-separated paths a payload request must target (e.g. /ssh); empty accepts any")

	flag.Parse()

	listeners, err := parseListeners(listenArgs)
	if err != nil {
		log.Fatalf("invalid -listen: %v", err)
	}

	payloadResponse, err := buildResponse(*payloadStatusArg)
	if err != nil {
		log.Fatalf("invalid -payload-status: %v", err)
	}
	connectResponse, err := buildResponse(*connectStatusArg)
	if err != nil {
		log.Fatalf("invalid -connect-status: %v", err)
	}
	if len(connectResponse) == 0 {
		log.Fatal("-connect-status must not be empty")
	}
	if *extraHeadsArg < 0 || *extraHeadsArg > 8 {
		log.Fatal("-payload-extra-heads must be between 0 and 8")
	}

	// Loaded up front so a bad path fails at startup rather than on the first
	// client's handshake.
	var tlsConfig *tls.Config
	if anyTLS(listeners) {
		if *certArg == "" || *keyArg == "" {
			log.Fatal("a :tls listener was configured but -cert/-key were not supplied")
		}
		cert, err := tls.LoadX509KeyPair(*certArg, *keyArg)
		if err != nil {
			log.Fatalf("loading TLS key pair: %v", err)
		}
		tlsConfig = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
	}

	paths, err := parsePaths(*pathArg)
	if err != nil {
		log.Fatalf("invalid -path: %v", err)
	}

	cfg := &config{
		sshBackend:       net.JoinHostPort(*sshHostArg, *sshPortArg),
		ovpnBackend:      net.JoinHostPort(*ovpnHostArg, *ovpnPortArg),
		connectTimeout:   time.Duration(*connTimeoutArg) * time.Second,
		handshakeTimeout: time.Duration(*handshakeTimeoutArg) * time.Second,
		payloadResponse:  payloadResponse,
		connectResponse:  connectResponse,
		payloadMatch:     *payloadMatchArg,
		paths:            paths,
		extraHeads:       *extraHeadsArg,
	}

	var sem chan struct{}
	if *maxConnsArg > 0 {
		sem = make(chan struct{}, *maxConnsArg)
	}

	// Bind everything before serving, so a clash or a privileged port without
	// permission is a startup failure rather than a listener that never accepts.
	sockets := make([]net.Listener, 0, len(listeners))
	for _, l := range listeners {
		s, err := bind(*hostArg, l, tlsConfig)
		if err != nil {
			for _, open := range sockets {
				_ = open.Close()
			}
			log.Fatalf("listening on %s: %v", l, err)
		}
		sockets = append(sockets, s)
	}

	var listenerWG, connWG sync.WaitGroup
	for i, l := range listeners {
		listenerWG.Add(1)
		go acceptLoop(sockets[i], l, cfg, sem, &listenerWG, &connWG)
		log.Printf("listening on %s:%s mode=%s tls=%t backend=%s", *hostArg, l.port, l.mode, l.useTLS, l.target)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan

	log.Printf("received %s, closing listeners", sig)
	for _, s := range sockets {
		_ = s.Close()
	}
	listenerWG.Wait()

	// Every accept loop has returned, so no further connections can be
	// registered and waiting on connWG is race-free.
	drained := make(chan struct{})
	go func() {
		connWG.Wait()
		close(drained)
	}()
	select {
	case <-drained:
		log.Print("all tunnels closed, exiting")
	case <-time.After(time.Duration(*shutdownGraceArg) * time.Second):
		log.Print("shutdown grace period expired, exiting with tunnels still open")
	}
}

// parseListeners accepts both "PORTS:MODE[:tls]" and a bare port list, the
// latter meaning direct over TLS so that units written for the TLS-only version
// keep working.
func parseListeners(args []string) ([]listener, error) {
	if len(args) == 0 {
		args = []string{"443:direct:tls"}
	}

	var out []listener
	for _, rawArg := range args {
		raw := strings.TrimSpace(rawArg)

		// The backend suffix is taken off before the colon fields are split, so
		// it cannot be confused with a mode or with "tls".
		tgt := targetSSH
		if i := strings.LastIndexByte(raw, '@'); i >= 0 {
			name := target(strings.ToLower(strings.TrimSpace(raw[i+1:])))
			switch name {
			case targetSSH, targetOVPN, targetAuto:
				tgt = name
			default:
				return nil, fmt.Errorf("unknown backend %q in %q (want ssh, ovpn or auto)", raw[i+1:], rawArg)
			}
			raw = strings.TrimSpace(raw[:i])
		}

		fields := strings.Split(raw, ":")
		if len(fields) > 3 {
			return nil, fmt.Errorf("expected PORTS:MODE[:tls][@BACKEND], got %q", rawArg)
		}

		m := modeDirect
		useTLS := len(fields) == 1
		if len(fields) >= 2 {
			m = mode(strings.ToLower(strings.TrimSpace(fields[1])))
			switch m {
			case modeDirect, modeConnect, modePayload, modeAuto:
			default:
				return nil, fmt.Errorf("unknown mode %q in %q (want direct, connect, payload or auto)", fields[1], rawArg)
			}
		}
		if len(fields) == 3 {
			if !strings.EqualFold(strings.TrimSpace(fields[2]), "tls") {
				return nil, fmt.Errorf("third field of %q must be \"tls\", got %q", rawArg, fields[2])
			}
			useTLS = true
		}

		for _, port := range strings.Split(fields[0], ",") {
			port = strings.TrimSpace(port)
			if port == "" {
				continue
			}
			n, err := strconv.Atoi(port)
			if err != nil || n < 1 || n > 65535 {
				return nil, fmt.Errorf("invalid port %q", port)
			}
			out = append(out, listener{port: port, mode: m, useTLS: useTLS, target: tgt})
		}
	}

	if len(out) == 0 {
		return nil, errors.New("no ports given")
	}
	seen := make(map[string]listener, len(out))
	for _, l := range out {
		if prev, dup := seen[l.port]; dup {
			return nil, fmt.Errorf("port %s is configured twice (%s and %s)", l.port, prev.mode, l.mode)
		}
		seen[l.port] = l
	}
	return out, nil
}

// buildResponse renders the payload reply. An empty status means "say nothing",
// which some clients expect. CR and LF are rejected so a status line cannot
// smuggle in extra headers.
func buildResponse(status string) ([]byte, error) {
	if strings.TrimSpace(status) == "" {
		return nil, nil
	}
	if strings.ContainsAny(status, "\r\n") {
		return nil, errors.New("status line must not contain CR or LF")
	}
	return []byte("HTTP/1.1 " + status + "\r\n\r\n"), nil
}

// parsePaths validates the -path list. Each entry must be absolute so it can be
// compared against a request target without guessing.
func parsePaths(list string) ([]string, error) {
	var out []string
	for _, raw := range strings.Split(list, ",") {
		path := strings.TrimSpace(raw)
		if path == "" {
			continue
		}
		if !strings.HasPrefix(path, "/") {
			return nil, fmt.Errorf("path %q must start with /", path)
		}
		out = append(out, path)
	}
	return out, nil
}

// requestPath extracts the target from an HTTP request line, tolerating the
// absolute form ("GET http://host/ssh HTTP/1.1") that proxied clients send, and
// dropping any query or fragment.
func requestPath(requestLine string) string {
	fields := strings.Fields(requestLine)
	if len(fields) < 2 {
		return ""
	}
	target := fields[1]

	if i := strings.Index(target, "://"); i >= 0 {
		rest := target[i+3:]
		if j := strings.IndexByte(rest, '/'); j >= 0 {
			target = rest[j:]
		} else {
			target = "/"
		}
	}
	if i := strings.IndexAny(target, "?#"); i >= 0 {
		target = target[:i]
	}
	return target
}

// pathAllowed reports whether the request targets one of the configured paths.
// A configured path matches itself and anything below it, so /ssh also accepts
// /ssh/anything, which is what clients appending a token or cache-buster send.
func pathAllowed(paths []string, target string) bool {
	if len(paths) == 0 {
		return true
	}
	for _, p := range paths {
		if target == p || strings.HasPrefix(target, strings.TrimSuffix(p, "/")+"/") {
			return true
		}
	}
	return false
}

func anyTLS(listeners []listener) bool {
	for _, l := range listeners {
		if l.useTLS {
			return true
		}
	}
	return false
}

func bind(host string, l listener, tlsConfig *tls.Config) (net.Listener, error) {
	address := net.JoinHostPort(host, l.port)
	if l.useTLS {
		return tls.Listen("tcp", address, tlsConfig)
	}
	return net.Listen("tcp", address)
}

func acceptLoop(s net.Listener, l listener, cfg *config, sem chan struct{},
	listenerWG, connWG *sync.WaitGroup) {
	defer listenerWG.Done()
	defer s.Close()

	var backoff time.Duration
	for {
		client, err := s.Accept()
		if err != nil {
			// A closed listener means shutdown, not a failure to retry.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Back off rather than spin: a persistent error such as EMFILE
			// would otherwise burn a core in a tight retry loop.
			if backoff == 0 {
				backoff = 5 * time.Millisecond
			} else if backoff < time.Second {
				backoff *= 2
			}
			log.Printf("[:%s] accept failed: %v (retrying in %v)", l.port, err, backoff)
			time.Sleep(backoff)
			continue
		}
		backoff = 0

		if sem != nil {
			select {
			case sem <- struct{}{}:
			default:
				log.Printf("[:%s] at -max-conns, refusing %s", l.port, client.RemoteAddr())
				_ = client.Close()
				continue
			}
		}

		connWG.Add(1)
		go func() {
			defer connWG.Done()
			if sem != nil {
				defer func() { <-sem }()
			}
			handleClient(client, l, cfg)
		}()
	}
}

// setKeepAlive enables TCP keepalive, unwrapping the TLS connection first: a
// type assertion to *net.TCPConn cannot match *tls.Conn, so without this a TLS
// listener would silently run without keepalive.
func setKeepAlive(conn net.Conn) {
	if tlsConn, ok := conn.(*tls.Conn); ok {
		conn = tlsConn.NetConn()
	}
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcpConn.SetKeepAlive(true)
	_ = tcpConn.SetKeepAlivePeriod(15 * time.Second)
}

func handleClient(client net.Conn, l listener, cfg *config) {
	defer client.Close()
	setKeepAlive(client)

	// tls.Conn handshakes lazily on the first read, so it is driven here with a
	// deadline. Otherwise a client that connects and sends nothing would hold a
	// goroutine and a file descriptor indefinitely.
	if tlsConn, ok := client.(*tls.Conn); ok {
		ctx, cancel := context.WithTimeout(context.Background(), cfg.handshakeTimeout)
		defer cancel()
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			log.Printf("[:%s] TLS handshake with %s failed: %v", l.port, client.RemoteAddr(), err)
			return
		}
	}

	// Anything the client sends after its handshake and before the relay starts
	// is buffered in this reader, so it has to be the relay's source. A direct
	// port with a fixed backend needs no reader at all and keeps the kernel copy
	// fast path.
	var clientSrc io.Reader = client
	var reader *bufio.Reader
	if l.mode != modeDirect || l.target == targetAuto {
		reader = bufio.NewReaderSize(client, relayBufferSize)
		clientSrc = reader
	}

	if l.mode != modeDirect {
		if err := client.SetReadDeadline(time.Now().Add(cfg.handshakeTimeout)); err != nil {
			return
		}
		if err := handshake(client, reader, l.mode, cfg); err != nil {
			log.Printf("[:%s] handshake from %s failed: %v", l.port, client.RemoteAddr(), err)
			return
		}
		// An established tunnel is long-lived and idle stretches are normal.
		if err := client.SetReadDeadline(time.Time{}); err != nil {
			return
		}
	}

	backend := cfg.sshBackend
	resolved := l.target
	if resolved == targetAuto {
		if err := client.SetReadDeadline(time.Now().Add(targetSniffTimeout)); err != nil {
			return
		}
		resolved = sniffTarget(reader)
		if err := client.SetReadDeadline(time.Time{}); err != nil {
			return
		}
	}
	if resolved == targetOVPN {
		backend = cfg.ovpnBackend
	}

	upstream, err := net.DialTimeout("tcp", backend, cfg.connectTimeout)
	if err != nil {
		log.Printf("[:%s] dialling %s backend %s failed: %v", l.port, resolved, backend, err)
		return
	}
	defer upstream.Close()
	setKeepAlive(upstream)

	relay(client, clientSrc, upstream)
}

func handshake(client net.Conn, reader *bufio.Reader, m mode, cfg *config) error {
	auto := m == modeAuto
	if auto {
		resolved, err := sniff(reader)
		if err != nil {
			return err
		}
		m = resolved
	}

	switch m {
	case modeDirect:
		// The client is already speaking SSH; nothing to negotiate.
		return nil

	case modeConnect:
		return handshakeConnect(client, reader, cfg.connectResponse)

	case modePayload:
		head, err := readRequestHead(reader)
		if err != nil {
			return fmt.Errorf("reading request head: %w", err)
		}
		if cfg.payloadMatch != "" && !strings.Contains(head, cfg.payloadMatch) {
			return fmt.Errorf("request head does not contain %q", cfg.payloadMatch)
		}
		if len(cfg.paths) > 0 {
			requestLine := head
			if i := strings.IndexByte(head, '\n'); i >= 0 {
				requestLine = head[:i]
			}
			target := requestPath(strings.TrimRight(requestLine, "\r\n"))
			if !pathAllowed(cfg.paths, target) {
				// 404 rather than a bare close, so a scanner sees an ordinary
				// web server instead of something that looks like a tunnel.
				_, _ = client.Write([]byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
				return fmt.Errorf("path %q is not allowed", target)
			}
		}
		// Clients that split their payload into several request blocks need the
		// extras consumed, or sshd would receive them as protocol garbage.
		for i := 0; i < cfg.extraHeads; i++ {
			if _, err := readRequestHead(reader); err != nil {
				return fmt.Errorf("reading extra request head %d: %w", i+1, err)
			}
		}
		// Payloads are often padded with blank lines. Only already-buffered
		// bytes are consumed, so this never waits for data the client is not
		// going to send.
		drainBufferedNewlines(reader)

		if len(cfg.payloadResponse) == 0 {
			return nil
		}
		_, err = client.Write(cfg.payloadResponse)
		return err
	}

	return fmt.Errorf("unhandled mode %q", m)
}

// sniffTarget decides which backend a tunnelled stream belongs to by looking at
// its first bytes. A client that sends nothing within the sniff window is taken
// to be SSH, because an OpenVPN client always speaks first.
func sniffTarget(reader *bufio.Reader) target {
	prefix, _ := reader.Peek(4)
	switch {
	case len(prefix) >= 4 && strings.EqualFold(string(prefix[:4]), "SSH-"):
		return targetSSH
	case looksLikeOpenVPN(prefix):
		return targetOVPN
	default:
		return targetSSH
	}
}

// looksLikeOpenVPN reports whether these bytes open an OpenVPN TCP session.
// Over TCP every OpenVPN packet is framed with a two-byte big-endian length,
// followed by a byte whose top five bits are the opcode; a client's first
// packet is always one of the hard-reset opcodes. An SSH banner cannot collide,
// because "SS" read as a length is far larger than any control packet.
func looksLikeOpenVPN(b []byte) bool {
	if len(b) < 3 {
		return false
	}
	length := int(b[0])<<8 | int(b[1])
	if length < 1 || length > 1600 {
		return false
	}
	switch b[2] >> 3 {
	case 1, 7, 10: // P_CONTROL_HARD_RESET_CLIENT_V1, V2, V3
		return true
	}
	return false
}

// sniff inspects the first bytes to decide how a client on an auto port wants
// to be greeted.
func sniff(reader *bufio.Reader) (mode, error) {
	// Peek returns short with an error if fewer bytes arrive; a client that
	// sends nothing is treated as already speaking SSH.
	prefix, err := reader.Peek(8)
	switch {
	case len(prefix) == 0:
		if err != nil {
			return "", fmt.Errorf("client sent nothing: %w", err)
		}
		return modeDirect, nil
	case hasFoldPrefix(prefix, "CONNECT "):
		return modeConnect, nil
	case hasFoldPrefix(prefix, "SSH-"):
		return modeDirect, nil
	default:
		return modePayload, nil
	}
}

func hasFoldPrefix(b []byte, prefix string) bool {
	if len(b) < len(prefix) {
		return false
	}
	return strings.EqualFold(string(b[:len(prefix)]), prefix)
}

// handshakeConnect implements the server half of an HTTP CONNECT proxy.
//
// The host:port the client asks for is deliberately ignored: every tunnel is
// relayed to the listener's configured backend. Honouring arbitrary targets would turn
// this into an open relay and get the server's address blocklisted.
func handshakeConnect(client net.Conn, reader *bufio.Reader, response []byte) error {
	head, err := readRequestHead(reader)
	if err != nil {
		return fmt.Errorf("reading CONNECT request: %w", err)
	}

	requestLine := head
	if i := strings.IndexByte(head, '\n'); i >= 0 {
		requestLine = head[:i]
	}
	requestLine = strings.TrimRight(requestLine, "\r\n")

	fields := strings.Fields(requestLine)
	if len(fields) == 0 || !strings.EqualFold(fields[0], "CONNECT") {
		_, _ = client.Write([]byte("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n"))
		return fmt.Errorf("expected a CONNECT request, got %q", requestLine)
	}

	drainBufferedNewlines(reader)
	_, err = client.Write(response)
	return err
}

// readRequestHead reads up to and including the blank line that ends an HTTP
// request head, refusing anything oversized rather than buffering it.
func readRequestHead(reader *bufio.Reader) (string, error) {
	var head strings.Builder
	for lines := 0; ; lines++ {
		if lines >= maxHeaderLines {
			return "", fmt.Errorf("request head exceeds %d lines", maxHeaderLines)
		}

		// ReadSlice reports ErrBufferFull instead of growing without bound, so
		// a single endless line cannot exhaust memory.
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			return "", fmt.Errorf("request head line exceeds %d bytes", relayBufferSize)
		}
		if err != nil {
			return "", err
		}
		if head.Len()+len(line) > maxHeaderBytes {
			return "", fmt.Errorf("request head exceeds %d bytes", maxHeaderBytes)
		}
		// line aliases the reader's buffer, so this copy must happen before the
		// next read.
		head.Write(line)

		if strings.TrimRight(string(line), "\r\n") == "" {
			return head.String(), nil
		}
	}
}

// drainBufferedNewlines discards padding newlines that are already buffered.
// Checking Buffered() first is what keeps this non-blocking: a bare Peek would
// wait out the whole handshake deadline on every connection whose client has
// finished sending and is waiting for the server to reply.
func drainBufferedNewlines(reader *bufio.Reader) {
	for reader.Buffered() > 0 {
		b, err := reader.Peek(1)
		if err != nil || (b[0] != '\r' && b[0] != '\n') {
			return
		}
		if _, err := reader.ReadByte(); err != nil {
			return
		}
	}
}

// relay copies in both directions until either side finishes, then closes both
// so the opposite copy cannot block forever.
func relay(client net.Conn, clientSrc io.Reader, upstream net.Conn) {
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			_ = client.Close()
			_ = upstream.Close()
		})
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer closeBoth()
		buf := make([]byte, relayBufferSize)
		_, _ = io.CopyBuffer(upstream, clientSrc, buf)
	}()

	buf := make([]byte, relayBufferSize)
	_, _ = io.CopyBuffer(client, upstream, buf)
	closeBoth()
	wg.Wait()
}
