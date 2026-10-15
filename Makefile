CODESIGN_ID ?= ribbon-cert

CLI_SOURCES := $(wildcard Sources/ribbon-cli/*.swift)
DAEMON_SOURCES := $(wildcard Sources/RibbonCore/*.swift) \
                  $(wildcard Sources/RibbonAccessibility/*.swift) \
                  $(wildcard Sources/ribbon-daemon/*.swift)

.PHONY: all cli daemon bundle clean restart

all: cli daemon bundle

restart: cli bundle
	bin/ribbon restart

cli: bin/ribbon

daemon: bin/ribbon-daemon

bundle: bin/Ribbon.app/Contents/_CodeSignature/CodeResources

bin/ribbon: $(CLI_SOURCES) | bin
	swiftc -O -o bin/ribbon Sources/ribbon-cli/main.swift
	codesign --force --sign "$(CODESIGN_ID)" bin/ribbon

bin/ribbon-daemon: $(DAEMON_SOURCES) | bin
	swiftc -O -o bin/ribbon-daemon -framework ApplicationServices -framework AppKit -framework Foundation -framework CoreGraphics -framework ColorSync Sources/RibbonCore/*.swift Sources/RibbonAccessibility/*.swift Sources/ribbon-daemon/*.swift
	codesign --force --sign "$(CODESIGN_ID)" bin/ribbon-daemon

bin/Ribbon.app/Contents/MacOS/ribbon-daemon: bin/ribbon-daemon
	mkdir -p bin/Ribbon.app/Contents/MacOS
	rm -f bin/Ribbon.app/Contents/MacOS/ribbon-daemon
	cp bin/ribbon-daemon bin/Ribbon.app/Contents/MacOS/ribbon-daemon

bin/Ribbon.app/Contents/Info.plist: Resources/Info.plist
	mkdir -p bin/Ribbon.app/Contents
	cp Resources/Info.plist bin/Ribbon.app/Contents/Info.plist

bin/Ribbon.app/Contents/_CodeSignature/CodeResources: bin/Ribbon.app/Contents/MacOS/ribbon-daemon bin/Ribbon.app/Contents/Info.plist
	codesign --force --sign "$(CODESIGN_ID)" bin/Ribbon.app

bin:
	mkdir -p bin

clean:
	rm -rf bin
