NAME := ppx_jsobject_conv
PREFIX = $(shell opam config var prefix)

build:
	cp pkg/META.in pkg/META
	ocaml pkg/build.ml native=true native-dynlink=true

ppx-jsobject:
	ocamlfind ocamlopt -predicates ppx_driver -o ppx-jsobject \
		_build/src/$(NAME).cmxa -linkpkg -package ppx_type_conv \
		-package ppx_driver ppx_driver_runner.cmxa

driver: build ppx-jsobject
# test: build
# 	rm -rf _build/src_test/
# 	ocamlbuild -j 0 -use-ocamlfind -classic-display \
# 						 src_test/test_ppx_yojson.byte --

doc:
	ocamlbuild -use-ocamlfind doc/api.docdir/index.html \
						 -docflags -t -docflag "API reference for ppx_deriving_yojson" \
						 -docflags '-colorize-code -short-functors -charset utf-8' \
						 -docflags '-css-style style.css'
	cp doc/style.css api.docdir/

$(NAME).install: build

clean:
	ocamlbuild -clean
	rm -f $(NAME).install

install: $(NAME).install
	opam-installer -i --prefix $(PREFIX) $(NAME).install

uninstall: $(NAME).install
	opam-installer -u --prefix $(PREFIX) $(NAME).install

reinstall: $(NAME).install
	opam-installer -u --prefix $(PREFIX) $(NAME).install &> /dev/null || true
	opam-installer -i --prefix $(PREFIX) $(NAME).install

.PHONY: build driver clean

# gh-pages: doc
# 	git clone `git config --get remote.origin.url` .gh-pages --reference .
# 	git -C .gh-pages checkout --orphan gh-pages
# 	git -C .gh-pages reset
# 	git -C .gh-pages clean -dxf
# 	cp -t .gh-pages/ api.docdir/*
# 	git -C .gh-pages add .
# 	git -C .gh-pages commit -m "Update Pages"
# 	git -C .gh-pages push origin gh-pages -f
# 	rm -rf .gh-pages

VERSION      := $$(opam query --version)
NAME_VERSION := $$(opam query --name-version)
ARCHIVE      := $$(opam query --archive)

# release:
# 	git tag -a v$(VERSION) -m "Version $(VERSION)."
# 	git push origin v$(VERSION)
# 	opam publish prepare $(NAME_VERSION) $(ARCHIVE)
# 	opam publish submit $(NAME_VERSION)
# 	rm -rf $(NAME_VERSION)

# .PHONY: gh-pages release
