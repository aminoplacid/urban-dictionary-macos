# Build the Urban Dictionary macOS dictionary.
# Requires macOS + Apple's "Dictionary Development Kit" (Xcode "Additional Tools").
#
#   make INPUT=data/urbandict-word-defs.csv          # convert + build
#   make install                                       # copy into ~/Library/Dictionaries
#   make FILTER="--min-up 200 --max-words 50000"       # tune filters

INPUT           ?= $(wildcard data/*.csv data/*.json data/*.jsonl)
FILTER          ?=
PYTHON          ?= python3

DICT_NAME        = "Urban Dictionary"
DICT_SRC_PATH    = build/UrbanDictionary.xml
CSS_PATH         = dictionary/UrbanDictionary.css
PLIST_PATH       = dictionary/UrbanDictionary.plist

DICT_BUILD_OPTS     ?=
DICT_BUILD_TOOL_DIR ?= /Applications/Utilities/Dictionary Development Kit
DICT_BUILD_TOOL_BIN  = $(DICT_BUILD_TOOL_DIR)/bin

DICT_DEV_KIT_OBJ_DIR = ./build/objects
export DICT_DEV_KIT_OBJ_DIR

DESTINATION_FOLDER = $(HOME)/Library/Dictionaries

.PHONY: all xml dict install uninstall clean test saver install-saver uninstall-saver

# ---- Screen saver (Command Line Tools only; no Xcode) ----------------------
SAVER_LIMIT   ?= 5000
SAVER_BUNDLE   = build/UrbanWordOfTheDay.saver
SAVER_BIN      = $(SAVER_BUNDLE)/Contents/MacOS/UrbanWordOfTheDay
SAVER_JSON     = build/words.json
SAVER_DEST     = $(HOME)/Library/Screen Savers/Urban Word of the Day.saver
SAVER_ARCHS   ?= -arch arm64 -arch x86_64

all: dict

xml: $(DICT_SRC_PATH)

$(DICT_SRC_PATH): ud2dict.py $(INPUT)
	@test -n "$(INPUT)" || { echo "No input. Put a dump in data/ or pass INPUT=path"; exit 1; }
	$(PYTHON) ud2dict.py $(INPUT) -o $@ $(FILTER)

dict: $(DICT_SRC_PATH)
	@test -x "$(DICT_BUILD_TOOL_BIN)/build_dict.sh" || { \
	  echo "Dictionary Development Kit not found at: $(DICT_BUILD_TOOL_DIR)"; \
	  echo "Download 'Additional Tools for Xcode' from developer.apple.com/download/all"; \
	  echo "and copy 'Utilities/Dictionary Development Kit' to /Applications/Utilities,"; \
	  echo "or pass DICT_BUILD_TOOL_DIR=/path/to/kit"; exit 1; }
	"$(DICT_BUILD_TOOL_BIN)/build_dict.sh" $(DICT_BUILD_OPTS) $(DICT_NAME) $(DICT_SRC_PATH) $(CSS_PATH) $(PLIST_PATH)

install:
	mkdir -p "$(DESTINATION_FOLDER)"
	ditto --noextattr --norsrc "$(DICT_DEV_KIT_OBJ_DIR)/Urban Dictionary.dictionary" "$(DESTINATION_FOLDER)/Urban Dictionary.dictionary"
	touch "$(DESTINATION_FOLDER)"
	@echo "Installed. Quit and reopen Dictionary.app, then enable it in Settings."

uninstall:
	rm -rf "$(DESTINATION_FOLDER)/Urban Dictionary.dictionary"

$(SAVER_JSON): ud2dict.py $(INPUT)
	@test -n "$(INPUT)" || { echo "No input. Put a dump in data/ or pass INPUT=path"; exit 1; }
	$(PYTHON) ud2dict.py $(INPUT) --saver-json $@ --saver-limit $(SAVER_LIMIT) $(FILTER)

$(SAVER_BIN): saver/UDWordOfTheDayView.m
	mkdir -p $(dir $@)
	clang -fobjc-arc -fmodules -bundle $(SAVER_ARCHS) -mmacosx-version-min=11.0 \
	  -framework Cocoa -framework ScreenSaver -o $@ $<

saver: $(SAVER_BIN) $(SAVER_JSON) saver/Info.plist
	mkdir -p $(SAVER_BUNDLE)/Contents/Resources
	cp saver/Info.plist $(SAVER_BUNDLE)/Contents/Info.plist
	cp $(SAVER_JSON) $(SAVER_BUNDLE)/Contents/Resources/words.json
	codesign --force --sign - $(SAVER_BUNDLE)
	@echo "Built $(SAVER_BUNDLE). Run 'make install-saver'."

install-saver: saver
	mkdir -p "$(HOME)/Library/Screen Savers"
	rm -rf "$(SAVER_DEST)"
	ditto "$(SAVER_BUNDLE)" "$(SAVER_DEST)"
	-killall legacyScreenSaver 2>/dev/null
	@echo "Installed. Open System Preferences > Desktop & Screen Saver and pick 'Urban Word of the Day'."

uninstall-saver:
	rm -rf "$(SAVER_DEST)"

test:
	$(PYTHON) -m unittest discover -s tests -v

clean:
	rm -rf build
