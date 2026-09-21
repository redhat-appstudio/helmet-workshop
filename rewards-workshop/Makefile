.PHONY: build installer-tar sync-apps clean deps

MCP_IMAGE ?= $(WORKSHOP_IMAGE)
INSTALLER_DIR := installer
TAR := $(INSTALLER_DIR)/installer.tar
# Rebuild the embed tarball whenever anything under installer/ changes (except the tar itself).
INSTALLER_SOURCES := $(shell find $(INSTALLER_DIR) -type f ! -name 'installer.tar' 2>/dev/null)

LDFLAGS :=
ifneq ($(MCP_IMAGE),)
LDFLAGS += -X main.defaultMCPImage=$(MCP_IMAGE)
endif

build: go.sum $(TAR)
	go build -mod=readonly $(if $(LDFLAGS),-ldflags "$(LDFLAGS)",) -o rewards-workshop .

go.sum: go.mod
	go mod download

deps: go.mod
	go mod tidy

installer-tar: sync-apps $(TAR)

sync-apps:
	mkdir -p $(INSTALLER_DIR)/bundles/producer/charts/order-producer/files/public
	mkdir -p $(INSTALLER_DIR)/bundles/consumer/charts/order-consumer/files/public
	cp ../apps/producer/{server.js,data.js,package.json} $(INSTALLER_DIR)/bundles/producer/charts/order-producer/files/
	cp ../apps/producer/public/* $(INSTALLER_DIR)/bundles/producer/charts/order-producer/files/public/
	cp ../apps/consumer/{server.js,data.js,package.json} $(INSTALLER_DIR)/bundles/consumer/charts/order-consumer/files/
	cp ../apps/consumer/public/* $(INSTALLER_DIR)/bundles/consumer/charts/order-consumer/files/public/

$(TAR): $(INSTALLER_SOURCES)
	@test -d $(INSTALLER_DIR) || (echo "missing $(INSTALLER_DIR)" && exit 1)
	@test -f $(INSTALLER_DIR)/helmet.yaml || (echo "create installer/helmet.yaml first (see workshop-activities.md or coordinator Lab activities)" && exit 1)
	tar -C $(INSTALLER_DIR) -cf $(TAR) \
		helmet.yaml config values.yaml.tpl bundles

clean:
	rm -f rewards-workshop $(TAR)
