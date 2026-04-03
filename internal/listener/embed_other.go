//go:build !darwin && !windows

package listener

// No embedded listener on unsupported platforms.
var embeddedBinary []byte
