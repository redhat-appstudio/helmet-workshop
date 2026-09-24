package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/redhat-appstudio/helmet-workshop/rewards-demo/installer"

	"github.com/redhat-appstudio/helmet/api"
	"github.com/redhat-appstudio/helmet/framework"
)

// Build-time default (override with MCP_IMAGE=... make build).
var defaultMCPImage = "quay.io/your-org/helmet-workshop:latest"

//go:generate make -C .. installer-tar

func mcpImageRef() string {
	if v := os.Getenv("WORKSHOP_IMAGE"); v != "" {
		return v
	}
	if v := os.Getenv("MCP_IMAGE"); v != "" {
		return v
	}
	if defaultMCPImage != "" {
		return defaultMCPImage
	}
	return "quay.io/your-org/helmet-workshop:latest"
}

// installerNamespace defaults config --create -n from the workshop pod env.
// Falls back to AppContext name (rewards-demo) when unset.
func installerNamespace() string {
	for _, key := range []string{"WORKSHOP_NAMESPACE", "HELMET_CONFIG_NAMESPACE"} {
		if ns := strings.TrimSpace(os.Getenv(key)); ns != "" {
			return ns
		}
	}
	return ""
}

func main() {
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get working directory: %v\n", err)
		os.Exit(1)
	}

	opts := []api.ContextOption{
		api.WithShortDescription("DevConf workshop: Helmet Corp rewards demo (instructor reference)"),
	}
	if ns := installerNamespace(); ns != "" {
		opts = append(opts, api.WithNamespace(ns))
	}

	appCtx := api.NewAppContext("rewards-demo", opts...)

	app, err := framework.NewAppFromTarball(
		appCtx,
		installer.InstallerTarball,
		cwd,
		framework.WithMCPImage(mcpImageRef()),
		framework.WithDistributedInstallerMergeLayout(),
		framework.WithVerifyRetries(1),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create application: %v\n", err)
		os.Exit(1)
	}

	if err := app.Run(); err != nil {
		os.Exit(1)
	}
}
