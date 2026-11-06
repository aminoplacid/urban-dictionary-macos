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

.PHONY: all xml dict install uninstall clean test

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

test:
	$(PYTHON) -m unittest discover -s tests -v

clean:
	rm -rf build
