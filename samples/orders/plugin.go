package orders

import (
	"embed"
	"fmt"
	"mime"
	"path/filepath"
	"strings"

	"github.com/GoCodeAlone/workflow/plugin/external/sdk"
)

//go:embed embedded/config.yaml
var configData []byte

//go:embed all:embedded/ui_dist
var uiDist embed.FS

// Plugin implements the orders sample app plugin.
type Plugin struct{}

// NewPlugin creates a new Plugin instance.
func NewPlugin() *Plugin {
	return &Plugin{}
}

// Manifest returns the plugin metadata.
func (p *Plugin) Manifest() sdk.PluginManifest {
	return sdk.PluginManifest{
		Name:           "sample-orders",
		Version:        "0.1.0",
		Author:         "GoCodeAlone",
		Description:    "Order Management sample app — CRUD orders with state machine transitions",
		ConfigMutable:  true,
		SampleCategory: "order-management",
	}
}

// ConfigFragment returns the embedded config.yaml bytes.
func (p *Plugin) ConfigFragment() ([]byte, error) {
	return configData, nil
}

// GetAsset returns a static asset from the embedded ui_dist directory.
func (p *Plugin) GetAsset(path string) ([]byte, string, error) {
	if path == "" || path == "/" {
		path = "index.html"
	}
	path = strings.TrimPrefix(path, "/")

	fullPath := filepath.Join("embedded", "ui_dist", path)
	content, err := uiDist.ReadFile(fullPath)
	if err != nil {
		return nil, "", fmt.Errorf("asset not found: %s", path)
	}

	contentType := mime.TypeByExtension(filepath.Ext(path))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	return content, contentType, nil
}

var _ sdk.PluginProvider = (*Plugin)(nil)
var _ sdk.ConfigProvider = (*Plugin)(nil)
var _ sdk.AssetProvider = (*Plugin)(nil)
