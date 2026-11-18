PREFIX ?= /usr/local

.PHONY: install uninstall lint test

install:
	install -D -m 0755 dskxp $(DESTDIR)$(PREFIX)/sbin/dskxp

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/sbin/dskxp

lint:
	shellcheck dskxp tests/loop-test.sh

test:
	sudo tests/loop-test.sh
