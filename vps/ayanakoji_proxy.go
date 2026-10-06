// Command ayanakoji_proxy accepts tunnel client connections, completes whatever
// handshake the client expects, and then relays the stream to a local SSH
// backend.
//
// Each listening port is configured independently with -listen PORTS:MODE[:tls]
// so one process can serve several client types at once:
//
//	ws       read an HTTP request head, reply "HTTP/1.1 101 ..." (websocket style)
//	connect  speak HTTP CONNECT, reply "HTTP/1.1 200 Connection established"
//	payload  read an HTTP request head, reply with a configurable status line
//	direct   no handshake at all, relay the raw stream immediately
//	auto     sniff the first bytes and pick connect, direct, ws or payload
//
// Example:
//
//	ayanakoji_proxy -listen 10080:ws -listen 8888:connect \
//	    -listen 10443:payload:tls -cert c.pem -key k.pem
package main

import (
	"bufio"
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
	// Relay buffer, also the bufio reader size, so a handshake head up to
	// maxHeaderBytes always fits without the reader reporting ErrBufferFull.
	relayBufferSize = 16 << 10

	// Bounds on the client handshake. Without these a peer can hold a
	// connection open while the server buffers an unbounded request head.
	maxHeaderBytes = 8 << 10
	maxHeaderLines = 100
)

type handshakeMode string

const (
	modeWS      handshakeMode = "ws"
	modeConnect handshakeMode = "connect"
	modePayload handshakeMode = "payload"
	modeDirect  handshakeMode = "direct"
	modeAuto    handshakeMode = "auto"
)

type listenerSpec struct {
	port   string
	mode   handshakeMode
	useTLS bool
}

func (s listenerSpec) String() string {
	if s.useTLS {
		return fmt.Sprintf(":%s (%s over tls)", s.port, s.mode)
	}
	return fmt.Sprintf(":%s (%s)", s.port, s.mode)
}

type config struct {
	sshHost          string
	sshPort          string
	connectTimeout   time.Duration
	handshakeTimeout time.Duration
	wsResponse       []byte
	payloadResponse  []byte
	payloadMatch     string
}

// repeatedFlag collects a flag that may be supplied more than once.
type repeatedFlag []string

func (f *repeatedFlag) String() string { return strings.Join(*f, " ") }

func (f *repeatedFlag) Set(v string) error {
	*f = append(*f, v)
	return nil
}

func main() {
	log.SetFlags(log.LstdFlags)

	var listenArgs repeatedFlag
	flag.Var(&listenArgs, "listen", "PORTS:MODE[:tls], repeatable (e.g. 8888:connect, 443:auto:tls)")

	portsArg := flag.String("ports", "", "Deprecated: plaintext ports served in ws mode")
	tlsPortsArg := flag.String("tls-ports", "", "Deprecated: TLS ports served in ws mode")

	certArg := flag.String("cert", "", "Path to the TLS certificate (required for any :tls listener)")
	keyArg := flag.String("key", "", "Path to the TLS private key (required for any :tls listener)")
	hostArg := flag.String("host", "0.0.0.0", "Address to bind")
	sshHostArg := flag.String("ssh-host", "127.0.0.1", "Upstream SSH host")
	sshPortArg := flag.String("ssh-port", "22", "Upstream SSH port")
	connTimeoutArg := flag.Int("connect-timeout-secs", 5, "Seconds to wait for the SSH backend")
	handshakeTimeoutArg := flag.Int("handshake-timeout-secs", 10, "Seconds a client has to finish its handshake")
	maxConnsArg := flag.Int("max-conns", 0, "Maximum concurrent tunnels (0 = unlimited)")
	shutdownGraceArg := flag.Int("shutdown-grace-secs", 10, "Seconds to let tunnels drain on SIGTERM")

	wsStatusArg := flag.String("ws-status", "101 <font color='red'><b>AYANAKOJIX!!!!</b></font>",
		"Status line returned by ws mode")
	payloadStatusArg := flag.String("payload-status", "200 OK",
		"Status line returned by payload mode (empty = reply with nothing)")
	payloadMatchArg := flag.String("payload-match", "",
		"If set, ws/payload clients must send this substring in their request head")

	flag.Parse()

	specs, err := collectSpecs(listenArgs, *portsArg, *tlsPortsArg)
	if err != nil {
		log.Fatalf("invalid listener configuration: %v", err)
	}
	if len(specs) == 0 {
		log.Fatal("no listeners configured: pass at least one -listen PORTS:MODE (see -h)")
	}

	wsResponse, err := buildResponse(*wsStatusArg, "Upgrade: websocket\r\nConnection: Upgrade\r\n")
	if err != nil {
		log.Fatalf("invalid -ws-status: %v", err)
	}
	payloadResponse, err := buildResponse(*payloadStatusArg, "")
	if err != nil {
		log.Fatalf("invalid -payload-status: %v", err)
	}

	cfg := &config{
		sshHost:          *sshHostArg,
		sshPort:          *sshPortArg,
		connectTimeout:   time.Duration(*connTimeoutArg) * time.Second,
		handshakeTimeout: time.Duration(*handshakeTimeoutArg) * time.Second,
		wsResponse:       wsResponse,
		payloadResponse:  payloadResponse,
		payloadMatch:     *payloadMatchArg,
	}

	// Load the key pair up front so a bad path fails at startup rather than on
	// the first TLS handshake of every connection.
	var tlsConfig *tls.Config
	if anyTLS(specs) {
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

	var sem chan struct{}
	if *maxConnsArg > 0 {
		sem = make(chan struct{}, *maxConnsArg)
	}

	// Bind everything before serving, so a port clash is a startup failure
	// instead of a listener that silently never accepts.
	listeners := make([]net.Listener, 0, len(specs))
	for _, spec := range specs {
		l, err := listen(*hostArg, spec, tlsConfig)
		if err != nil {
			for _, open := range listeners {
				_ = open.Close()
			}
			log.Fatalf("listening on %s: %v", spec, err)
		}
		listeners = append(listeners, l)
	}

	var listenerWG, connWG sync.WaitGroup
	for i, spec := range specs {
		listenerWG.Add(1)
		go acceptLoop(listeners[i], spec, cfg, sem, &listenerWG, &connWG)
		log.Printf("listening on %s:%s mode=%s tls=%t -> %s", *hostArg, spec.port, spec.mode, spec.useTLS,
			net.JoinHostPort(cfg.sshHost, cfg.sshPort))
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan

	log.Printf("received %s, closing listeners", sig)
	for _, l := range listeners {
		_ = l.Close()
	}
	listenerWG.Wait()

	// No new connections can be registered now that every accept loop has
	// returned, so waiting on connWG is race-free.
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

// collectSpecs merges the -listen flags with the legacy -ports/-tls-ports flags,
// which are kept so existing systemd units keep working unchanged.
func collectSpecs(listenArgs []string, ports, tlsPorts string) ([]listenerSpec, error) {
	var specs []listenerSpec
	for _, raw := range listenArgs {
		parsed, err := parseListenSpec(raw)
		if err != nil {
			return nil, err
		}
		specs = append(specs, parsed...)
	}
	for _, p := range splitPorts(ports) {
		if err := validatePort(p); err != nil {
			return nil, err
		}
		specs = append(specs, listenerSpec{port: p, mode: modeWS})
	}
	for _, p := range splitPorts(tlsPorts) {
		if err := validatePort(p); err != nil {
			return nil, err
		}
		specs = append(specs, listenerSpec{port: p, mode: modeWS, useTLS: true})
	}

	seen := make(map[string]listenerSpec, len(specs))
	for _, s := range specs {
		if prev, dup := seen[s.port]; dup {
			return nil, fmt.Errorf("port %s is configured twice (%s and %s)", s.port, prev.mode, s.mode)
		}
		seen[s.port] = s
	}
	return specs, nil
}

func parseListenSpec(raw string) ([]listenerSpec, error) {
	fields := strings.Split(raw, ":")
	if len(fields) < 2 || len(fields) > 3 {
		return nil, fmt.Errorf("expected PORTS:MODE[:tls], got %q", raw)
	}

	mode := handshakeMode(strings.ToLower(strings.TrimSpace(fields[1])))
	switch mode {
	case modeWS, modeConnect, modePayload, modeDirect, modeAuto:
	default:
		return nil, fmt.Errorf("unknown mode %q in %q (want ws, connect, payload, direct or auto)", fields[1], raw)
	}

	useTLS := false
	if len(fields) == 3 {
		if !strings.EqualFold(strings.TrimSpace(fields[2]), "tls") {
			return nil, fmt.Errorf("third field of %q must be \"tls\", got %q", raw, fields[2])
		}
		useTLS = true
	}

	var specs []listenerSpec
	for _, p := range splitPorts(fields[0]) {
		if err := validatePort(p); err != nil {
			return nil, err
		}
		specs = append(specs, listenerSpec{port: p, mode: mode, useTLS: useTLS})
	}
	if len(specs) == 0 {
		return nil, fmt.Errorf("no ports given in %q", raw)
	}
	return specs, nil
}

func splitPorts(list string) []string {
	var out []string
	for _, p := range strings.Split(list, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func validatePort(p string) error {
	n, err := strconv.Atoi(p)
	if err != nil || n < 1 || n > 65535 {
		return fmt.Errorf("invalid port %q", p)
	}
	return nil
}

func anyTLS(specs []listenerSpec) bool {
	for _, s := range specs {
		if s.useTLS {
			return true
		}
	}
	return false
}

// buildResponse renders a handshake reply. An empty status means "say nothing",
// which some payload clients expect. CR and LF are rejected so a status line
// cannot smuggle in extra headers.
func buildResponse(status, extraHeaders string) ([]byte, error) {
	if strings.TrimSpace(status) == "" {
		return nil, nil
	}
	if strings.ContainsAny(status, "\r\n") {
		return nil, errors.New("status line must not contain CR or LF")
	}
	return []byte("HTTP/1.1 " + status + "\r\n" + extraHeaders + "\r\n"), nil
}

func listen(host string, spec listenerSpec, tlsConfig *tls.Config) (net.Listener, error) {
	address := net.JoinHostPort(host, spec.port)
	if spec.useTLS {
		return tls.Listen("tcp", address, tlsConfig)
	}
	return net.Listen("tcp", address)
}

func acceptLoop(l net.Listener, spec listenerSpec, cfg *config, sem chan struct{},
	listenerWG, connWG *sync.WaitGroup) {
	defer listenerWG.Done()
	defer l.Close()

	var backoff time.Duration
	for {
		client, err := l.Accept()
		if err != nil {
			// A closed listener means shutdown, not a failure to retry.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Back off instead of spinning: a permanent error such as EMFILE
			// would otherwise burn a core in a tight retry loop.
			if backoff == 0 {
				backoff = 5 * time.Millisecond
			} else if backoff < time.Second {
				backoff *= 2
			}
			log.Printf("[:%s] accept failed: %v (retrying in %v)", spec.port, err, backoff)
			time.Sleep(backoff)
			continue
		}
		backoff = 0

		if sem != nil {
			select {
			case sem <- struct{}{}:
			default:
				log.Printf("[:%s] at -max-conns, refusing %s", spec.port, client.RemoteAddr())
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
			handleClient(client, spec, cfg)
		}()
	}
}

// setKeepAlive enables TCP keepalive, unwrapping a TLS connection first: the
// type assertion to *net.TCPConn fails on *tls.Conn, so a TLS listener would
// otherwise silently run without keepalive.
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

func handleClient(client net.Conn, spec listenerSpec, cfg *config) {
	defer client.Close()
	setKeepAlive(client)

	reader := bufio.NewReaderSize(client, relayBufferSize)

	// The handshake is the only phase with a deadline; an established tunnel is
	// long-lived and idle stretches are normal.
	if err := client.SetReadDeadline(time.Now().Add(cfg.handshakeTimeout)); err != nil {
		return
	}
	if err := performHandshake(client, reader, spec.mode, cfg); err != nil {
		log.Printf("[:%s] handshake from %s failed: %v", spec.port, client.RemoteAddr(), err)
		return
	}
	if err := client.SetReadDeadline(time.Time{}); err != nil {
		return
	}

	backend := net.JoinHostPort(cfg.sshHost, cfg.sshPort)
	upstream, err := net.DialTimeout("tcp", backend, cfg.connectTimeout)
	if err != nil {
		log.Printf("[:%s] dialling backend %s failed: %v", spec.port, backend, err)
		return
	}
	defer upstream.Close()
	setKeepAlive(upstream)

	relay(client, reader, upstream)
}

// performHandshake completes the client-side negotiation for the listener's
// mode, leaving the connection ready to carry SSH bytes.
func performHandshake(client net.Conn, reader *bufio.Reader, mode handshakeMode, cfg *config) error {
	auto := mode == modeAuto
	if auto {
		resolved, err := sniffMode(reader)
		if err != nil {
			return err
		}
		mode = resolved
	}

	switch mode {
	case modeDirect:
		// Nothing to negotiate; the client speaks SSH straight away.
		return nil

	case modeConnect:
		return handshakeConnect(client, reader)

	case modeWS, modePayload:
		head, err := readRequestHead(reader)
		if err != nil {
			return fmt.Errorf("reading request head: %w", err)
		}
		if cfg.payloadMatch != "" && !strings.Contains(head, cfg.payloadMatch) {
			return fmt.Errorf("request head does not contain %q", cfg.payloadMatch)
		}
		// Tunnel clients often pad the payload with extra blank lines. Only
		// already-buffered bytes are consumed, so this never blocks waiting for
		// data the client is not going to send.
		drainBufferedNewlines(reader)

		response := cfg.payloadResponse
		if mode == modeWS {
			response = cfg.wsResponse
		}
		if auto && strings.Contains(strings.ToLower(head), "upgrade: websocket") {
			response = cfg.wsResponse
		}
		if len(response) == 0 {
			return nil
		}
		_, err = client.Write(response)
		return err
	}

	return fmt.Errorf("unhandled handshake mode %q", mode)
}

// sniffMode inspects the first bytes to decide how a client on an auto port
// wants to be greeted.
func sniffMode(reader *bufio.Reader) (handshakeMode, error) {
	// Peek returns short with an error if the client sends fewer bytes; a silent
	// client is treated as a raw SSH stream.
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
		// An HTTP-ish head of some kind; the exact reply is chosen once the
		// head has been read and can be checked for an Upgrade header.
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
// relayed to the configured SSH backend. Honouring arbitrary targets would turn
// this into an open relay and get the VPS address blocklisted.
func handshakeConnect(client net.Conn, reader *bufio.Reader) error {
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
	_, err = client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
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

		// ReadSlice reports ErrBufferFull instead of growing without bound, so a
		// single endless line cannot exhaust memory.
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
		// line aliases the reader's buffer, so Write's copy must happen before
		// the next read.
		head.Write(line)

		if strings.TrimRight(string(line), "\r\n") == "" {
			return head.String(), nil
		}
	}
}

// drainBufferedNewlines discards padding newlines that are already buffered.
// Checking Buffered() first is what keeps this non-blocking: a bare Peek would
// wait for the full handshake deadline on every connection whose client has
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
func relay(client net.Conn, buffered io.Reader, upstream net.Conn) {
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
		// buffered wraps client and still holds any bytes read past the
		// handshake, so it must be the source rather than client itself.
		buf := make([]byte, relayBufferSize)
		_, _ = io.CopyBuffer(upstream, buffered, buf)
	}()

	buf := make([]byte, relayBufferSize)
	_, _ = io.CopyBuffer(client, upstream, buf)
	closeBoth()
	wg.Wait()
}
