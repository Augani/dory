package main

import (
	"log"
)

const agentPort = 1024

func main() {
	startHostAIBridge()
	listener, err := listenVsock(agentPort)
	if err != nil {
		log.Printf("rpc vsock listener disabled: %v", err)
		select {}
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go func() {
			defer conn.Close()
			if err := serveRPC(conn); err != nil {
				log.Printf("rpc: %v", err)
			}
		}()
	}
}
