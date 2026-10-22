# Installs to ~/.local/bin by default (no sudo needed).
# Elsewhere: make install PREFIX=/opt/homebrew  or  sudo make install PREFIX=/usr/local
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: build install uninstall test e2e

build:
	swift build -c release

# Under sudo, don't build: it would leave root-owned files in .build. Run `make build` first.
install:
	@if [ "$$(id -u)" != 0 ]; then swift build -c release; \
	elif [ ! -x .build/release/xcsrclink ]; then echo "error: run 'make build' (without sudo) first" >&2; exit 1; fi
	@mkdir -p "$(BINDIR)" 2>/dev/null; \
	if [ ! -w "$(BINDIR)" ]; then \
	  echo "error: $(BINDIR) is not writable. Use a different PREFIX, e.g. 'make install PREFIX=$$HOME/.local', or run 'make build' then 'sudo make install PREFIX=$(PREFIX)'." >&2; \
	  exit 1; \
	fi
	install -m 755 .build/release/xcsrclink "$(BINDIR)/xcsrclink"
	@echo "Installed $(BINDIR)/xcsrclink"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "note: $(BINDIR) is not on your PATH" ;; esac

uninstall:
	rm -f "$(BINDIR)/xcsrclink"

test:
	swift test

e2e:
	scripts/e2e.sh
