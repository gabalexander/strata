SWIFT = swift build --disable-sandbox
.PHONY: build app install checks snapshots clean

build:
	$(SWIFT)

app:
	./scripts/build-app.sh

install: app
	./scripts/install.sh

checks:
	$(SWIFT) --product StrataChecks
	.build/debug/StrataChecks

snapshots:
	$(SWIFT) --product StrataSnapshot
	.build/debug/StrataSnapshot build/snapshots

clean:
	rm -rf build .build
