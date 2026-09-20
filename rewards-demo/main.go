package main

import (
	"fmt"
	"os"

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

func main() {
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get working directory: %v\n", err)
		os.Exit(1)
	}

	appCtx := api.NewAppContext(
		"rewards-demo",
		api.WithShortDescription("DevConf workshop: Helmet Corp rewards demo (instructor reference)"),
	)

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
