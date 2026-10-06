// Command ayanakoji_proxy terminates TLS on one or more ports and relays each
// connection, byte for byte, to a local SSH server.
//
// There is no HTTP, websocket or CONNECT handshake: a client opens a TLS
// connection and speaks SSH inside it immediately. That is the whole protocol.
//
//	ayanakoji_proxy -listen 443 -cert /path/cert.pem -key /path/key.pem
package main

import (
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

// Relay buffer size. io.CopyBuffer prefers the kernel fast path on TCP
// connections and falls back to this.
const relayBufferSize = 16 << 10

func main() {
	log.SetFlags(log.LstdFlags)

	portsArg := flag.String("listen", "443", "Comma-separated TLS ports to accept SSH on")
	hostArg := flag.String("host", "0.0.0.0", "Address to bind")
	certArg := flag.String("cert", "", "Path to the TLS certificate chain (required)")
	keyArg := flag.String("key", "", "Path to the TLS private key (required)")
	sshHostArg := flag.String("ssh-host", "127.0.0.1", "Upstream SSH host")
	sshPortArg := flag.String("ssh-port", "22", "Upstream SSH port")
	connTimeoutArg := flag.Int("connect-timeout-secs", 5, "Seconds to wait for the SSH backend")
	handshakeTimeoutArg := flag.Int("handshake-timeout-secs", 10, "Seconds a client has to finish the TLS handshake")
	maxConnsArg := flag.Int("max-conns", 0, "Maximum concurrent tunnels (0 = unlimited)")
	shutdownGraceArg := flag.Int("shutdown-grace-secs", 10, "Seconds to let tunnels drain on SIGTERM")

	flag.Parse()

	ports, err := parsePorts(*portsArg)
	if err != nil {
		log.Fatalf("invalid -listen: %v", err)
	}
	if *certArg == "" || *keyArg == "" {
		log.Fatal("-cert and -key are required")
	}

	// Loaded up front so a bad path or an unreadable key fails at startup
	// rather than on the first client's handshake.
	cert, err := tls.LoadX509KeyPair(*certArg, *keyArg)
	if err != nil {
		log.Fatalf("loading TLS key pair: %v", err)
	}
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	backend := net.JoinHostPort(*sshHostArg, *sshPortArg)
	cfg := &config{
		backend:          backend,
		connectTimeout:   time.Duration(*connTimeoutArg) * time.Second,
		handshakeTimeout: time.Duration(*handshakeTimeoutArg) * time.Second,
	}

	var sem chan struct{}
	if *maxConnsArg > 0 {
		sem = make(chan struct{}, *maxConnsArg)
	}

	// Bind every port before serving, so a clash or a privileged port without
	// permission is a startup failure instead of a listener that never accepts.
	listeners := make([]net.Listener, 0, len(ports))
	for _, port := range ports {
		address := net.JoinHostPort(*hostArg, port)
		l, err := tls.Listen("tcp", address, tlsConfig)
		if err != nil {
			for _, open := range listeners {
				_ = open.Close()
			}
			log.Fatalf("listening on %s: %v", address, err)
		}
		listeners = append(listeners, l)
	}

	var listenerWG, connWG sync.WaitGroup
	for i, port := range ports {
		listenerWG.Add(1)
		go acceptLoop(listeners[i], port, cfg, sem, &listenerWG, &connWG)
		log.Printf("accepting SSH over TLS on %s:%s -> %s", *hostArg, port, backend)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigChan

	log.Printf("received %s, closing listeners", sig)
	for _, l := range listeners {
		_ = l.Close()
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

type config struct {
	backend          string
	connectTimeout   time.Duration
	handshakeTimeout time.Duration
}

func parsePorts(list string) ([]string, error) {
	var ports []string
	seen := make(map[string]bool)
	for _, raw := range strings.Split(list, ",") {
		port := strings.TrimSpace(raw)
		if port == "" {
			continue
		}
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return nil, fmt.Errorf("invalid port %q", port)
		}
		if seen[port] {
			return nil, fmt.Errorf("port %s listed twice", port)
		}
		seen[port] = true
		ports = append(ports, port)
	}
	if len(ports) == 0 {
		return nil, errors.New("no ports given")
	}
	return ports, nil
}

func acceptLoop(l net.Listener, port string, cfg *config, sem chan struct{},
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
			// Back off rather than spin: a persistent error such as EMFILE
			// would otherwise burn a core in a tight retry loop.
			if backoff == 0 {
				backoff = 5 * time.Millisecond
			} else if backoff < time.Second {
				backoff *= 2
			}
			log.Printf("[:%s] accept failed: %v (retrying in %v)", port, err, backoff)
			time.Sleep(backoff)
			continue
		}
		backoff = 0

		if sem != nil {
			select {
			case sem <- struct{}{}:
			default:
				log.Printf("[:%s] at -max-conns, refusing %s", port, client.RemoteAddr())
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
			handleClient(client, port, cfg)
		}()
	}
}

// setKeepAlive enables TCP keepalive, unwrapping the TLS connection first: a
// type assertion to *net.TCPConn cannot match *tls.Conn, so without this every
// tunnel would run without keepalive and idle NAT entries would be dropped
// silently.
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

func handleClient(client net.Conn, port string, cfg *config) {
	defer client.Close()
	setKeepAlive(client)

	// tls.Conn handshakes lazily on the first read, so it is driven here with a
	// deadline. Otherwise a client that connects and sends nothing would hold a
	// goroutine and a file descriptor indefinitely.
	if tlsConn, ok := client.(*tls.Conn); ok {
		ctx, cancel := context.WithTimeout(context.Background(), cfg.handshakeTimeout)
		defer cancel()
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			log.Printf("[:%s] TLS handshake with %s failed: %v", port, client.RemoteAddr(), err)
			return
		}
	}

	upstream, err := net.DialTimeout("tcp", cfg.backend, cfg.connectTimeout)
	if err != nil {
		log.Printf("[:%s] dialling backend %s failed: %v", port, cfg.backend, err)
		return
	}
	defer upstream.Close()
	setKeepAlive(upstream)

	relay(client, upstream)
}

// relay copies in both directions until either side finishes, then closes both
// so the opposite copy cannot block forever.
func relay(client, upstream net.Conn) {
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
		_, _ = io.CopyBuffer(upstream, client, buf)
	}()

	buf := make([]byte, relayBufferSize)
	_, _ = io.CopyBuffer(client, upstream, buf)
	closeBoth()
	wg.Wait()
}
