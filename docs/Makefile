# The site, with the web pages under /play/: the top-level doc-build builds
# both (it needs the Zig toolchain for the wasm).
build:
	$(MAKE) -C .. doc-build

deploy: build
	hop3 deploy --context prod -y

clean:
	rm -rf site
