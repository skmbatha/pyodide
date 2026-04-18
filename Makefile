PYODIDE_ROOT=$(abspath .)

include Makefile.envs

# KM: This means, always run if "make check", "make check-emcc" or
# it's a dependancy on another recipe. But there is no real target on disk
# they represent. So they always run when indexed, either in cmd args or as dependancies.
.PHONY: check check-emcc

CC=emcc
CXX=em++


all: \
	all-but-packages \
	dist/pyodide-lock.json \
	dist/pyodide.d.ts \
	dist/snapshot.bin \


all-but-packages: \
	check \
	check-emcc \
	$(CPYTHONINSTALL)/.installed-pyodide \
	dist/pyodide.asm.mjs \
	dist/pyodide.js \
	dist/package.json \
	dist/python \
	dist/python.bat \
	dist/python_cli_entry.mjs \
	dist/python_stdlib.zip \
	dist/test.html \
	dist/console.html \
	dist/console-v2.html \
	dist/module_test.html \


src/core/pyodide_pre.gen.dat: src/js/generated/_pyodide.out.js src/core/pre.js src/core/stack_switching/stack_switching.out.js
# Our goal here is to inject src/js/generated/_pyodide.out.js into an archive
# file so that when linked, Emscripten will include it. We use the same pathway
# that EM_JS uses, but EM_JS is itself unsuitable. Why? Because the C
# preprocessor / compiler modified strings and there is no "raw" strings
# feature. In particular, it seems to choke on regex in the JavaScript code. Our
# bundle includes vendored npm packages which we have no control over, so it is
# not simple to rewrite the code to restrict it to syntax that is legal inside
# of EM_JS.
#
# To get around this problem, we use an array initializer instead of a string
# initializer, with #embed.
#
# EM_JS works by injecting a string variable into a special section called em_js
# called __em_js__<function_name>. The contents of this variable are of the form
# "argspec<::>body". The argspec is used to generate the JavaScript function
# declaration:
# https://github.com/emscripten-core/emscripten/blob/085fe968d43c7d3674376f29667d6e5f42b24966/emscripten.py?plain=1#L603
#
# The body has to start with a function block, but it is possible to inject
# extra stuff after the block ends. We make a 0-argument function called
# pyodide_js_init. Immediately after that we inject pre.js and then a call to
# the init function.
	rm -f $@
	echo '()<::>{' >> $@                       # zero argument argspec and start body
	cat src/js/generated/_pyodide.out.js >> $@ # All of _pyodide.out.js is body
	echo '}' >> $@                             # Close function body
	cat src/core/stack_switching/stack_switching.out.js >> $@
	cat src/core/pre.js >> $@                  # Execute pre.js too
	echo "pyodide_js_init();" >> $@            # Then execute the function.


# Don't use ccache here because it does not support #embed properly.
# https://github.com/ccache/ccache/discussions/1366
src/core/pyodide_pre.o: src/core/pyodide_pre.c src/core/pyodide_pre.gen.dat emsdk/emsdk/.complete
	unset _EMCC_CCACHE && emcc --std=c23 -c $< -o $@

src/core/jsverror.wasm: src/core/jsverror.wat emsdk/emsdk/.complete
	./emsdk/emsdk/upstream/bin/wasm-as $< -o $@ -all

# KM: Create library from JS inject output (pyodide_pre.o) and C object files but not the main.o (but it was also)
# already built to an .o file, just don't add it to the library
src/core/libpyodide.a: \
	src/core/docstring.o \
	src/core/error_handling.o \
	src/core/hiwire.o \
	src/core/_pyodide_core.o \
	src/core/js2python.o \
	src/core/jsproxy.o \
	src/core/jsproxy_call.o \
	src/core/jsbind.o \
	src/core/pyproxy.o \
	src/core/python2js_buffer.o \
	src/core/jslib.o \
	src/core/jsbind.o \
	src/core/python2js.o \
	src/core/pyodide_pre.o \ # KM: This is generated from the JS output embedded in the C file
	src/core/stack_switching/pystate.o \
	src/core/stack_switching/suspenders.o \
	src/core/print.o \
	src/core/socket_syscalls.o

	emar rcs src/core/libpyodide.a $(filter %.o,$^)

# KM: Create dir if not exists, and copy all updated core/*.h files to it
# KM: The destination folder is "cpython/install/include/pyodide/..."
# KM: Also, add ".installed" dummy file to the same folder
# KM: $? means - All prerequisitetest newer than the target
$(CPYTHONINSTALL)/include/pyodide/.installed: src/core/*.h
	mkdir -p $(@D)
	cp $? $(@D)
	touch $@

# KM: Copy "libpyodide.a" from the src/core to the "cpython/install/lib/" folder
# KN: Make directory if it doesn't exists
$(CPYTHONINSTALL)/lib/libpyodide.a: src/core/libpyodide.a
	mkdir -p $(@D)
	cp $< $@

# KM: Create "/cpython/install/.installed-pyodide" if 'header files are copied' and lib file is built
# It just means pyodide's JS and C files' library is built and ready
$(CPYTHONINSTALL)/.installed-pyodide: $(CPYTHONINSTALL)/include/pyodide/.installed $(CPYTHONINSTALL)/lib/libpyodide.a
	touch $@

# KM: Create  a dist folder if it doesn't exist
# KM: main.o is. dependancy
# KM: Make all pyfiles inside "src/py/lib/*.py" dependancies. NB: This directory doesn't seem to exist
# KM: "$(CPYTHONLIB)" check if the directory's timestamp has changed. NB: A directory's timestamp
# updates when files are added or removed from it, but not when files inside it are modified.
# KM: "$(CPYTHONINSTALL)/.installed-pyodide" Checks if a JS and C lib file is built
dist/pyodide.asm.mjs: \
	dist \
	src/core/main.o  \
	$(wildcard src/py/lib/*.py) \
	$(CPYTHONLIB) \
	$(CPYTHONINSTALL)/.installed-pyodide

	@date +"[%F %T] Building pyodide.asm.mjs..."

   # TODO(ryanking13): Link libgl to a side module not to the main module.
   # For unknown reason, a side module cannot see symbols when libGL is linked to it.

   # KM: -lpyodide will look for "libpyodide.a" in the folders specified to emcc via "-L", see LDFLAGS_BASE in MAIN_MODULE_LDFLAGS
   # -lpython3.14.a is also linked though the "MAIN_MODULE_LDFLAGS" definition.

   # KM: Other static libraries (starts with -l<name>) linked though MAIN_MODULE_LDFLAGS libraries are also
   # in cpython/installs/lib/...

   # KM: The additional "-l<name>.js" files are defined in EMSCRIPTEN. You don't provide these and they
   # explicitly live in folder "emsdk/emsdk/upstream/emscripten/src/"

	embuilder build libgl
	$(CXX) -o dist/pyodide.asm.mjs -lpyodide src/core/main.o $(MAIN_MODULE_LDFLAGS)

  # KM: This runs a prettier code formatter for "pyodide.asm.mjs" and stores in the same file (NB: -w)
  # only if the conditions are met, if in debug,...
	if [[ -n $${PYODIDE_SOURCEMAP+x} ]] || [[ -n $${PYODIDE_SYMBOLS+x} ]] || [[ -n $${PYODIDE_DEBUG_JS+x} ]]; then \
		cd dist && npx prettier -w pyodide.asm.mjs ; \
	fi

   # Strip out C++ symbols which all start __Z.
   # There are 4821 of these and they have VERY VERY long names.
   # To show some stats on the symbols you can use the following:
   # cat dist/pyodide.asm.mjs | grep -ohE 'var _{0,5}.' | sort | uniq -c | sort -nr | head -n 20
	$(SED) -i -E 's/var __Z[^;]*;//g' dist/pyodide.asm.mjs
	@date +"[%F %T] done building pyodide.asm.mjs."

# KM: Prints all environment variables on the terminal
env:
	env

# KM: Installs all exact versions of node_modules through "npm ci" from "package-lock.json"
# This recipe will ensure, the modules are reinstalled if the package.json or lock have changed
# The result is a .installed file will be creted in the "node_modules" folder.
node_modules/.installed: src/js/package.json src/js/package-lock.json
	cd src/js && npm ci
	ln -sfn src/js/node_modules/ node_modules
	touch $@

# KM: builds "_pyodide.out.js" if any of the dependancies including the node modules change
# NB: this is the output injected into the WASM binary and ultimately "pyodide.asm.mjs"
src/js/generated/_pyodide.out.js:            \
		src/js/*.ts                          \
		src/js/common/*                      \
		src/js/vendor/*                      \
		src/js/generated/pyproxy.ts          \
		src/js/generated/python2js_buffer.js \
		src/js/generated/js2python.js        \
		node_modules/.installed
	cd src/js && npm run build-inner && cd -

# KM: Builds (using outer) the final pyodide.js, and references the pyodide.asm.mjs
# it doesn't re-bundle "pyodide.asm.mjs", but the API and other deps, i.e.,
# pyodide.ts, compat.ts, emscripten-settings.ts, version.ts
dist/pyodide.js:                             \
		dist/pyodide.asm.mjs            		 \
		src/js/generated/_pyodide.out.js  	 \
		src/js/pyodide.ts                    \
		src/js/compat.ts                     \
		src/js/emscripten-settings.ts        \
		src/js/version.ts                    \
		src/core/jsverror.wasm
	cd src/js && npm run build

# ...some JS packaging stuff...
src/core/stack_switching/stack_switching.out.js: src/core/stack_switching/*.mjs node_modules/.installed
	node src/core/stack_switching/esbuild.config.mjs

# ...some JS packaging stuff...
dist/package.json: src/js/package.json dist
	cp $< $@

# ... setup for testing ...
.PHONY: npm-link
npm-link: dist/package.json
	cd src/test-js && npm ci && npm link ../../dist

# Creates type defs using python & store them in dist
dist/pyodide.d.ts dist/pyodide/ffi.d.ts: dist/pyodide.js src/js/*.ts src/js/generated/pyproxy.ts node_modules/.installed
	npx dts-bundle-generator src/js/{pyodide,ffi}.ts --export-referenced-types false --project src/js/tsconfig.json
	mv src/js/{pyodide,ffi}.d.ts dist
	python3 tools/fixup-type-definitions.py dist/pyodide.d.ts
	python3 tools/fixup-type-definitions.py dist/ffi.d.ts


define preprocess-js

src/js/generated/$1: $(CPYTHONLIB) src/core/$1 src/core/pyproxy.c src/core/*.h
	# We can't input a js/ts file directly because CC will be unhappy about the file
	# extension. Instead cat it and have CC read from stdin.
	# -E : Only apply prepreocessor
	# -C : Leave comments alone (this allows them to be preserved in typescript
	#      definition files, rollup will strip them out)
	# -P : Don't put in macro debug info
	# -imacros pyproxy.c : include all of the macros definitions from pyproxy.c
	#
	# First we use sed to delete the segments of the file between
	# "// pyodide-skip" and "// end-pyodide-skip". This allows us to give
	# typescript type declarations for the macros which we need for intellisense
	# and documentation generation. The result of processing the type
	# declarations with the macro processor is a type error, so we snip them
	# out.
	rm -f $$@
	mkdir -p src/js/generated
	echo "// This file is generated by applying the C preprocessor to src/core/$1" >> $$@
	echo "// Do not edit it directly!" >> $$@
	cat src/core/$1 | \
		$(SED) '/^\/\/\s*pyodide-skip/,/^\/\/\s*end-pyodide-skip/d' | \
		$(CC) -E -C -P -imacros src/core/pyproxy.c $(MAIN_MODULE_CFLAGS) - | \
		$(SED) 's/^#pragma clang.*//g' \
		>> $$@
endef


$(eval $(call preprocess-js,pyproxy.ts))
$(eval $(call preprocess-js,python2js_buffer.js))
$(eval $(call preprocess-js,js2python.js))

pyodide_build .pyodide_build_installed:
	pip install -e ./pyodide-build
	@which pyodide >/dev/null
	touch .pyodide_build_installed


# Recursive wildcard
rwildcard=$(wildcard $1) $(foreach d,$1,$(call rwildcard,$(addsuffix /$(notdir $d),$(wildcard $(dir $d)*))))

# KM: Create the dist directory if it doesn't exist
dist:
	[ -d dist ] || mkdir dist

# KM: Using python scipt in tools, zip the python's standard lib, while excluding defs in PYZIP_EXCLUDE_FILES
dist/python_stdlib.zip: $(call rwildcard,src/py/*) $(CPYTHONLIB)
	./tools/create_zipfile.py $(CPYTHONLIB) src/py --exclude "$(PYZIP_EXCLUDE_FILES)" --stub "$(PYZIP_JS_STUBS)" --compression-level "$(PYODIDE_ZIP_COMPRESSION_LEVEL)" --output $@

#-----------------------------------------
# KM: Copy files from 'templates' to dist
#-----------------------------------------

dist/test.html: src/templates/test.html dist
	cp $< $@

dist/makesnap.mjs: src/templates/makesnap.mjs dist
	cp $< $@

dist/snapshot.bin: all-but-packages dist/pyodide-lock.json dist/makesnap.mjs
	cd dist && node --experimental-wasm-stack-switching makesnap.mjs

dist/module_test.html: src/templates/module_test.html dist
	cp $< $@

dist/python: src/templates/python dist
	cp $< $@

dist/python.bat: src/templates/python.bat dist
	cp $< $@


# KM: Build the python.exe application
dist/python.exe: src/templates/python_exe.go dist
	@if command -v go >/dev/null 2>&1; then \
		cd src/templates && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o ../../dist/python.exe -ldflags='-s -w' python_exe.go && \
		echo "Successfully built python.exe"; \
	elif [ -n "$$CI" ]; then \
		echo "ERROR: Go not found in CI environment" >&2; \
		exit 1; \
	else \
		echo "WARNING: Go not found. Skipping python.exe build."; \
	fi

dist/python_cli_entry.mjs: src/templates/python_cli_entry.mjs dist
	cp $< $@


.PHONY: dist/console.html dist/console-v2.html
dist/console.html: src/templates/console.html dist
	cp $< $@
	$(SED) -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@

dist/console-v2.html: src/templates/console-v2.html dist
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@


# KM: Prepare the dist directory for the release by removing unneeded files
.PHONY: clean-dist-dir
clean-dist-dir:
	# Remove snapshot files
	rm dist/makesnap.mjs
	rm dist/snapshot.bin
	rm dist/module_test.html dist/test.html

	# TODO: Source maps aren't useful outside of debug builds I don't think. But
	# removing them adds "missing sourcemap" warnings to JS console. We should
	# not generate them in the first place?
	# rm dist/*.map

# KM: Run lint
.PHONY: lint
lint:
	prek -a --show-diff-on-failure

benchmark: all
	$(HOSTPYTHON) benchmark/benchmark.py all --output dist/benchmarks.json
	$(HOSTPYTHON) benchmark/plot_benchmark.py dist/benchmarks.json dist/benchmarks.png

# KM: Clean only the pyodide project, not cpython or emsdk
clean:
	rm -fr dist
	rm -fr node_modules
	find src -name '*.o' -delete
	find src -name '*.wasm' -delete
	find src -name '*.gen.*' -delete
	find src -name '*.out.*' -delete
	rm -fr src/js/generated
	make -C packages clean
	rm -f .pyodide_build_installed
	echo "The Emsdk, CPython are not cleaned. cd into those directories to do so."

# KM: Clean Python
clean-python: clean
	make -C cpython clean

# KM: Clean all: pyodide, cpython & emsdk
clean-all: clean
	make -C emsdk clean
	make -C cpython clean-all

# KM: If any of the c files changes, rebuild to .o files
%.o: %.c $(CPYTHONLIB) $(wildcard src/core/*.h src/core/*.js)
	$(CC) -o $@ -c $< $(MAIN_MODULE_CFLAGS) -Isrc/core/

# KM: Build cpython [navigate to cpython and run the make file], this is probably maintained by
# CPythom
$(CPYTHONLIB): emsdk/emsdk/.complete
	@date +"[%F %T] Building cpython..."
	make -C $(CPYTHONROOT)
	@date +"[%F %T] done building cpython..."

# KM: Build the packages-lock file from packages (by running make there)
dist/pyodide-lock.json: $(CPYTHONLIB) .pyodide_build_installed
	@date +"[%F %T] Building packages..."
	make -C packages
	@date +"[%F %T] done building packages..."

# KM: Build emsdk (run make from emsdk)
emsdk/emsdk/.complete:
	@date +"[%F %T] Building emsdk..."
	make -C emsdk
	@date +"[%F %T] done building emsdk."

# KM: Downloads the rustup & sets it up, it's probably for some RUST related stuff
# I saw some of these during testing
rust:
	echo -e '\033[0;31m[WARNING] The target `make rust` is only for development and we do not guarantee that it will work or be maintained.\033[0m'
	wget -q -O - https://sh.rustup.rs | sh -s -- -y
	source $(HOME)/.cargo/env && rustup toolchain install $(RUST_TOOLCHAIN) && rustup default $(RUST_TOOLCHAIN)
	source $(HOME)/.cargo/env && rustup target add wasm32-unknown-emscripten --toolchain $(RUST_TOOLCHAIN)

# KM: Runs a shell script that verifies all system dependencies are installed before attempting a build. It likely checks for things like:
# emcc / em++ — Emscripten compiler
# node / npm — Node.js toolchain
# python3 — host Python
# cmake, make — build tools
# git — for submodules
#
# NB: @  - prefix suppresses 'make' from printing the command itself you only see the script's own output.
check:
	@./tools/dependency-check.sh


# KM: Runs after emsdk is built (note the emsdk/emsdk/.complete dependency) and specifically checks the ccache + emcc integration.
# It likely verifies:
#
# - Whether ccache is wrapping emcc correctly
# - Whether the ccache version supports Emscripten properly
# - Warns if ccache is misconfigured — because a broken ccache silently produces wrong results or slows builds down rather than speeding them up

check-emcc: emsdk/emsdk/.complete
	@python3 tools/check_ccache.py

# KM: Run using debug
debug:
	EXTRA_CFLAGS+=" -D DEBUG_F" \
	make

# KM: pyodide py-compile is a CLI tool from the pyodide-build package
# (installed via pip install -e ./pyodide-build). It walks through dist/ and
# compiles all .py files to .pyc bytecode.
#
# KM: By pre-compiling to .pyc ahead of time, step 1-3 are skipped at import
# time — which matters a lot in the browser where CPython startup and stdlib
# import speed is noticeable to the user.
.PHONY: py-compile
py-compile:
	pyodide py-compile --compression-level "$(PYODIDE_ZIP_COMPRESSION_LEVEL)" --exclude "$(PYCOMPILE_EXCLUDE_FILES)" dist/
