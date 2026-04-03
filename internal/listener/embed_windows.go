//go:build windows

package listener

import (
	_ "embed"
)

//go:embed speak-listen.exe
var embeddedBinary []byte
