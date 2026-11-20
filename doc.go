// Package netconnector documents the net-connector module: device
// interaction for network operations tools built on netops.
//
//	transport   opens byte streams: ssh (x/crypto/ssh), telnet
//	terminal    holds the CLI conversation a Grammar declares
//	driver      the platform contract and optional capabilities
//	vendors     the built-in platforms and their registry
//	connector   logged-in sessions implementing the netops ops ports
//	connectortest  a scripted fake device for byte-exact tests
//
// The root package holds no code.
package netconnector
