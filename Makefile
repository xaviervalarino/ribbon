CODESIGN_ID ?= -

CLI_SOURCES := $(wildcard Sources/ribbon-cli/*.swift)
DAEMON_SOURCES := $(wildcard Sources/RibbonCore/*.swift) \
                  $(wildcard Sources/RibbonAccessibility/*.swift) \
                  $(wildcard Sources/ribbon-daemon/*.swift)

.PHONY: all cli daemon sign clean

all: cli daemon sign

cli: bin/ribbon

daemon: bin/ribbon-daemon

bin/ribbon: $(CLI_SOURCES) | bin
	swiftc -O -o bin/ribbon Sources/ribbon-cli/main.swift

bin/ribbon-daemon: $(DAEMON_SOURCES) | bin
	swiftc -O -o bin/ribbon-daemon -framework ApplicationServices -framework AppKit -framework Foundation -framework CoreGraphics Sources/RibbonCore/*.swift Sources/RibbonAccessibility/*.swift Sources/ribbon-daemon/*.swift

sign: bin/ribbon-daemon bin/ribbon
	codesign --force --sign "$(CODESIGN_ID)" bin/ribbon-daemon bin/ribbon

bin:
	mkdir -p bin

clean:
	rm -rf bin
