// The other end of the interoperability check: a gRPC server and client written
// against the Go implementation, speaking the same one method this library does.
//
// No .proto and no generated code: the message type here is a byte string, which
// is exactly what crosses a gRPC boundary, and a passthrough codec is all that is
// needed to hand those bytes to the framework. What the check proves is the wire —
// HPACK headers, the five-octet length prefix, the `grpc-status` trailer — not a
// schema both sides were generated from.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// rawCodec carries a message as the bytes it already is.
type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) {
	switch m := v.(type) {
	case *[]byte:
		return *m, nil
	case []byte:
		return m, nil
	}
	return nil, fmt.Errorf("rawCodec: cannot marshal %T", v)
}

func (rawCodec) Unmarshal(data []byte, v any) error {
	switch m := v.(type) {
	case *[]byte:
		*m = append([]byte(nil), data...)
		return nil
	}
	return fmt.Errorf("rawCodec: cannot unmarshal into %T", v)
}

// Name is never negotiated: both ends are forced onto this codec, so the
// content-type stays the plain `application/grpc` any gRPC peer sends.
func (rawCodec) Name() string { return "raw" }

// echoService is only here because a ServiceDesc wants a handler type.
type echoService interface{}

var echoDesc = grpc.ServiceDesc{
	ServiceName: "interop.Echo",
	HandlerType: (*echoService)(nil),
	Methods: []grpc.MethodDesc{{
		MethodName: "Call",
		Handler: func(_ any, _ context.Context, dec func(any) error, _ grpc.UnaryServerInterceptor) (any, error) {
			in := []byte{}
			if err := dec(&in); err != nil {
				return nil, err
			}
			out := in
			return &out, nil
		},
	}},
	Metadata: "interop",
}

func main() {
	mode := flag.String("mode", "serve", "serve or call")
	addr := flag.String("addr", "127.0.0.1:12011", "host:port")
	message := flag.String("msg", "from-go", "the message a call sends")
	flag.Parse()

	switch *mode {
	case "serve":
		serve(*addr)
	case "call":
		call(*addr, *message)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q\n", *mode)
		os.Exit(2)
	}
}

func serve(addr string) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	server := grpc.NewServer(grpc.ForceServerCodec(rawCodec{}))
	server.RegisterService(&echoDesc, struct{}{})
	// The line the harness waits for: the port is bound and the process is ready.
	fmt.Println("serving", addr)
	if err := server.Serve(listener); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func call(addr, message string) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	req := []byte(message)
	var reply []byte
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err = conn.Invoke(ctx, "/interop.Echo/Call", &req, &reply, grpc.ForceCodec(rawCodec{}))
	if err != nil {
		log.Fatalf("call: %v", err)
	}
	fmt.Printf("reply %s\n", string(reply))
}
