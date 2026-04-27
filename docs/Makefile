# Makefile — KV32 Docs: AsciiDoc → PDF
#
# Targets:
#   make [all]    — build all PDFs
#   make setup    — install asciidoctor + asciidoctor-pdf (requires gem)
#   make clean    — remove generated PDFs
#
# Usage:
#   make                         # build everything
#   make jv32_soc_datasheet.pdf  # build one file
#   make setup                   # install tools (once)

ASCIIDOCTOR_PDF ?= asciidoctor-pdf

# Themes selection
#THEMES          ?= riscv-pdf
THEMES          ?= jv32-tech-report

CHECK_DOC       ?= jv32_soc_datasheet.adoc
CHECK_THEMES    ?= riscv-pdf jv32-tech-report

# Common flags for all documents
ADOC_FLAGS := -a toc \
              -a toclevels=3 \
              -a sectnums \
              -a icons=font \
              -a source-highlighter=rouge \
	      -r asciidoctor-mathematical \
              -a pdf-fontsdir="$(HOME)/.local/share/fonts;GEM_FONTS_DIR" \
			  -a pdf-themesdir=themes

THEME_FLAG := -a pdf-theme=$(THEMES)

SRCS := $(wildcard *.adoc)
PDFS := $(SRCS:.adoc=.pdf)

.PHONY: all setup clean docs-check

all: $(PDFS)

%.pdf: %.adoc
	$(ASCIIDOCTOR_PDF) $(ADOC_FLAGS) $(THEME_FLAG) -r asciidoctor-diagram -o $@ $<
	@$(RM) -rf images .asciidoctor package-lock.json package.json diag-ditaa-*.svg diag-ditaa-*.png

docs-check:
	@set -e; \
	for theme in $(CHECK_THEMES); do \
		echo "==> Checking theme $$theme with $(CHECK_DOC)"; \
		$(ASCIIDOCTOR_PDF) $(ADOC_FLAGS) -a pdf-theme=$$theme -r asciidoctor-diagram -o /tmp/jv32-docs-check-$$theme.pdf $(CHECK_DOC); \
		$(RM) -f /tmp/jv32-docs-check-$$theme.pdf; \
	done
	@$(RM) -rf images .asciidoctor package-lock.json package.json diag-ditaa-*.svg diag-ditaa-*.png

# ── Setup ─────────────────────────────────────────────────────────────────────

.PHONY: setup
setup:
	@echo "=== Installing asciidoctor and asciidoctor-pdf ==="
	gem install --user-install asciidoctor
	gem install --user-install asciidoctor-pdf
	gem install --user-install asciidoctor-diagram
	gem install --user-install rouge
	@echo "=== Done. Run 'asciidoctor-pdf --version' to verify ==="

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f $(PDFS)
