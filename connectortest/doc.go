// Package connectortest provides a scripted fake device for testing
// conversations byte for byte, without a network or a real device.
//
// A Script is the exact dialogue: what the device sends and the exact bytes
// it expects back. The fake device fails the test on the first unexpected
// byte, so a test proves which keystrokes a session sends, including the
// absence of a second password or an unwanted "y".
//
// Passing these tests is evidence about the session logic only. It is not
// evidence that a real device behaves like the script.
package connectortest
