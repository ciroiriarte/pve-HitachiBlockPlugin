include version.mk

DESTDIR=
PREFIX=/usr
PERL_VENDORLIB=$(PREFIX)/share/perl5

PLUGIN_SRC=src/PVE/Storage/Custom/HitachiBlockPlugin.pm
MODULE_DIR=src/PVE/Storage/HitachiBlock
MODULES=$(wildcard $(MODULE_DIR)/*.pm)

CONF_FILES=conf/storage.cfg.example conf/multipath.conf.d/hitachiblock-vsp.conf

# systemd units shipped (DISABLED) for opt-in SCSI-3 PR (#2): the qemu-pr-helper
# binary ships with pve-qemu-kvm but Proxmox does not package these units.
SYSTEMD_UNITS=conf/systemd/qemu-pr-helper.socket conf/systemd/qemu-pr-helper.service
SYSTEMD_UNIT_DIR=/lib/systemd/system

# Web UI (manager6) integration
GUI_SRC=src/www/manager6/hitachiblock.js
PVE_MANAGER_JS=/usr/share/pve-manager/js
INDEX_TPL=/usr/share/pve-manager/index.html.tpl

.PHONY: all install clean deb test obs-source

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

	# systemd units for opt-in SCSI-3 PR (#2), installed DISABLED. The .deb
	# leaves them inactive via dh_installsystemd --no-enable --no-start; the
	# operator enables the socket only when using persistent_reservations.
	install -d $(DESTDIR)$(SYSTEMD_UNIT_DIR)
	install -m 0644 $(SYSTEMD_UNITS) $(DESTDIR)$(SYSTEMD_UNIT_DIR)/

	# Documentation
	install -d $(DESTDIR)/usr/share/doc/$(PACKAGE)
	install -m 0644 $(CONF_FILES) $(DESTDIR)/usr/share/doc/$(PACKAGE)/

	# Web UI module (served at /pve2/js/pve-storage-hitachiblock.js)
	install -d $(DESTDIR)$(PVE_MANAGER_JS)
	install -m 0644 $(GUI_SRC) $(DESTDIR)$(PVE_MANAGER_JS)/pve-storage-hitachiblock.js
	# For source installs (empty DESTDIR) wire the <script> tag into the live
	# index template. The .deb does this via a dpkg trigger instead (see
	# debian/postinst + debian/triggers), so it survives pve-manager upgrades.
	@if [ -z "$(DESTDIR)" ] && [ -f "$(INDEX_TPL)" ]; then \
	  if grep -q 'pve-storage-hitachiblock.js' "$(INDEX_TPL)"; then \
	    sed -i 's#pve-storage-hitachiblock.js?ver=[^"]*#pve-storage-hitachiblock.js?ver=$(VERSION)#' "$(INDEX_TPL)"; \
	    echo "Refreshed Hitachi Block UI <script> cache-buster to $(VERSION) in $(INDEX_TPL) (reload the web UI with Ctrl-Shift-R)."; \
	  else \
	    sed -i '\#pvemanagerlib.js#a\<script type="text/javascript" src="/pve2/js/pve-storage-hitachiblock.js?ver=$(VERSION)"></script>' "$(INDEX_TPL)"; \
	    echo "Injected Hitachi Block UI <script> into $(INDEX_TPL) (reload the web UI with Ctrl-Shift-R)."; \
	  fi; \
	fi

test:
	prove -Isrc -r t/unit/

clean:
	rm -rf build/

deb:
	dpkg-buildpackage -us -uc -b

# Debian "3.0 (quilt)" source package for OBS (no dpkg-dev required)
obs-source:
	tools/make-obs-source.sh
