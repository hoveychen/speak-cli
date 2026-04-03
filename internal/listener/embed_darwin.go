//go:build darwin

package listener

import (
	_ "embed"
)

//go:embed speak-listen
var embeddedBinary []byte
