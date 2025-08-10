package manifest

import (
	"crypto/ed25519"
)

func SignManifest(priv ed25519.PrivateKey, data []byte) []byte {
	return ed25519.Sign(priv, data)
}

func VerifyManifest(pub ed25519.PublicKey, data, sig []byte) bool {
	return ed25519.Verify(pub, data, sig)
}
