PREFIX  ?= /usr/local
MANDIR  ?= $(PREFIX)/man

.PHONY: all clean install test

all:

test:
	perl -Ilib -c pldock
	prove t/*.t
	-mandoc -T lint pldock.1 pldock.conf.1

clean:

install:
	install -d $(DESTDIR)$(PREFIX)/bin
	install -d $(DESTDIR)$(PREFIX)/libdata/perl5/site_perl
	install -d $(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock
	install -d $(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin
	install -d $(DESTDIR)$(PREFIX)/share/examples/pldock
	install -d $(DESTDIR)$(MANDIR)/man1
	install -m 755 pldock $(DESTDIR)$(PREFIX)/bin/pldock
	install -m 644 lib/Pldock.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock.pm
	install -m 644 lib/Pldock/Plugin.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin.pm
	install -m 644 lib/Pldock/Plugin/Xloadio.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin/Xloadio.pm
	install -m 644 lib/Pldock/Plugin/Script.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin/Script.pm
	install -m 644 lib/Pldock/Plugin/Barrel.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin/Barrel.pm
	install -m 644 lib/Pldock/Plugin/Cube.pm \
		$(DESTDIR)$(PREFIX)/libdata/perl5/site_perl/Pldock/Plugin/Cube.pm
	install -m 644 pldock.conf \
		$(DESTDIR)$(PREFIX)/share/examples/pldock/pldock.conf
	install -m 644 pldock.1 $(DESTDIR)$(MANDIR)/man1/pldock.1
	install -m 644 pldock.conf.1 $(DESTDIR)$(MANDIR)/man1/pldock.conf.1
