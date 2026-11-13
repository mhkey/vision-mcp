APP := build/VisionMCP.app
SIGN_IDENTITY ?= -

.PHONY: build app run stop clean

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp "$$(swift build -c release --show-bin-path)/VisionMCP" $(APP)/Contents/MacOS/VisionMCP
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

run: app
	open $(APP)

stop:
	-pkill -x VisionMCP

clean:
	rm -rf .build build
