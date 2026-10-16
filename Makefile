CODESIGN_ID ?= ribbon-cert

CLI_SOURCES := $(wildcard Sources/ribbon-cli/*.swift)
DAEMON_SOURCES := $(wildcard Sources/RibbonCore/*.swift) \
                  $(wildcard Sources/RibbonAccessibility/*.swift) \
                  $(wildcard Sources/ribbon-daemon/*.swift) \
                  $(wildcard Sources/ribbon-daemon/WindowManager/*.swift)

.PHONY: all cli daemon bundle clean start restart test

all: cli daemon bundle

test: bin/test-runner
	bin/test-runner

bin/test-runner: $(wildcard Sources/RibbonCore/*.swift) Tests/RibbonCoreTests.swift | bin
	swiftc -o bin/test-runner -framework Foundation -framework CoreGraphics Sources/RibbonCore/*.swift Tests/RibbonCoreTests.swift

start: cli bundle
	bin/ribbon start

restart: cli bundle
	bin/ribbon restart

cli: bin/ribbon

daemon: bin/ribbon-daemon

bundle: bin/Ribbon.app/Contents/_CodeSignature/CodeResources

bin/ribbon: $(CLI_SOURCES) | bin
	swiftc -O -o bin/ribbon Sources/ribbon-cli/main.swift
	codesign --force --sign "$(CODESIGN_ID)" bin/ribbon

bin/ribbon-daemon: $(DAEMON_SOURCES) | bin
	swiftc -O -o bin/ribbon-daemon -framework ApplicationServices -framework AppKit -framework Foundation -framework CoreGraphics -framework ColorSync Sources/RibbonCore/*.swift Sources/RibbonAccessibility/*.swift Sources/ribbon-daemon/*.swift $$(ls Sources/ribbon-daemon/WindowManager/*.swift 2>/dev/null)
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
