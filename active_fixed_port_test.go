package goftp

import (
	"testing"
)

// Active mode with a fixed listen port must survive an operation that
// needs a second data connection.
//
// Reported upstream as secsy/goftp#66: a server answering "500 Command
// not found" to MLSD makes ReadDir fall back to LIST, which needs
// another data connection — and binding the same fixed port again fails,
// because the listener from the refused MLSD was never released.
//
// The reporter's own diagnosis was right: "it looks like the internal
// logic listens on the same address multiple times".
func TestActiveTransferWithAFixedPortSurvivesAFallback(t *testing.T) {
	requireServers(t)

	for _, addr := range ftpdAddrs {
		config := goftpConfig
		config.ActiveTransfers = true
		// A fixed port, which is the whole point — with ":0" the kernel
		// hands out a different one each time and the bug cannot happen.
		config.ActiveListenAddr = ":24999"
		// Refuse MLSD, so ReadDir has to fall back to LIST and ask for a
		// second data connection.
		config.stubResponses = map[string]stubResponse{
			"MLSD .": {500, "Command not found"},
		}

		c, err := DialConfig(config, addr)
		if err != nil {
			t.Fatalf("%s: %v", addr, err)
		}

		entries, err := c.ReadDir(".")
		if err != nil {
			t.Errorf("%s: ReadDir with a fixed active port: %v", addr, err)
		} else if len(entries) == 0 {
			t.Errorf("%s: ReadDir returned nothing", addr)
		}

		// And again, because the second operation is where the first
		// leaked listener would still be holding the port.
		if _, err := c.ReadDir("."); err != nil {
			t.Errorf("%s: a second ReadDir with a fixed active port: %v", addr, err)
		}

		c.Close()
	}
}
