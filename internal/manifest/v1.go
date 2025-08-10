package manifest

import "time"

type Manifest struct {
	Schema   string    `json:"schema"`
	Chain    string    `json:"chain"`
	Client   Client    `json:"client"`
	Height   int64     `json:"height"`
	Time     time.Time `json:"timestamp"`
	Roots    Roots     `json:"roots"`
	Artifact Artifact  `json:"artifact"`
	Checks   Checks    `json:"checks"`
	Sigs     []Sig     `json:"signatures"`
}

type Client struct {
	Name    string   `json:"name"`
	Version string   `json:"version"`
	Flags   []string `json:"flags"`
}

type Roots struct {
	StateRoot    string `json:"stateRoot"`
	BlockHash    string `json:"blockHash"`
	TxRoot       string `json:"txRoot"`
	ReceiptsRoot string `json:"receiptsRoot"`
}

type Artifact struct {
	Layout   string   `json:"layout"`
	Compress Compress `json:"compress"`
	Parts    []Part   `json:"parts"`
}

type Compress struct {
	Algo      string `json:"algo"`
	Dict      string `json:"dict"`
	ChunkSize string `json:"chunkSize"`
}

type Part struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	Sha256 string `json:"sha256"`
	URL    string `json:"url"`
}

type Checks struct {
	ManifestSha256 string `json:"manifestSha256"`
}

type Sig struct {
	Alg string `json:"alg"`
	Pub string `json:"pub"`
	Sig string `json:"sig"`
}
