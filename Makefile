include version.mk

DESTDIR=
PREFIX=/usr
PERL_VENDORLIB=$(PREFIX)/share/perl5

PLUGIN_SRC=src/PVE/Storage/Custom/HitachiBlockPlugin.pm
MODULE_DIR=src/PVE/Storage/HitachiBlock
MODULES=$(wildcard $(MODULE_DIR)/*.pm)

CONF_FILES=conf/storage.cfg.example conf/multipath.conf.d/hitachiblock-vsp.conf

.PHONY: all install clean deb test

all:
	@echo "$(PACKAGE) $(VERSION) - nothing to build (pure Perl)"

install:
	# Plugin entry point
	install -d $(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/Custom
	install -m 0644 $(PLUGIN_SRC) $(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/Custom/

	# Helper modules
	install -d $(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/HitachiBlock
	install -m 0644 $(MODULES) $(DESTDIR)$(PERL_VENDORLIB)/PVE/Storage/HitachiBlock/

	# CLI tools
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 bin/hitachiblock-repl $(DESTDIR)$(PREFIX)/bin/

	# Documentation
	install -d $(DESTDIR)/usr/share/doc/$(PACKAGE)
	install -m 0644 $(CONF_FILES) $(DESTDIR)/usr/share/doc/$(PACKAGE)/

test:
	prove -Isrc -r t/unit/

clean:
	@echo "Nothing to clean"

deb:
	dpkg-buildpackage -us -uc -b
