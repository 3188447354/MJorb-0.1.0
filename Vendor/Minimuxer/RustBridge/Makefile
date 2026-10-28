TARGET=rust_bridge
RUST_DIR="."
SCHEME=Minimuxer
BUILD_DIR=lib
FRAMEWORK_NAME=Minimuxer

# RustBridge 位于 <repo>/Vendor/Minimuxer/RustBridge，仓库根在上三级。
# CI 会显式传入绝对路径；本地手动 make 时用默认相对路径。
REPO_ROOT ?= ../../..

IPHONEOS_DEPLOYMENT_TARGET ?= 17.4
CFLAGS_aarch64_apple_ios ?= -miphoneos-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
CXXFLAGS_aarch64_apple_ios ?= -miphoneos-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
CFLAGS_aarch64_apple_ios_sim ?= -mios-simulator-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
CXXFLAGS_aarch64_apple_ios_sim ?= -mios-simulator-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
CFLAGS_x86_64_apple_ios ?= -mios-simulator-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
CXXFLAGS_x86_64_apple_ios ?= -mios-simulator-version-min=$(IPHONEOS_DEPLOYMENT_TARGET)
export IPHONEOS_DEPLOYMENT_TARGET
export CFLAGS_aarch64_apple_ios CXXFLAGS_aarch64_apple_ios
export CFLAGS_aarch64_apple_ios_sim CXXFLAGS_aarch64_apple_ios_sim
export CFLAGS_x86_64_apple_ios CXXFLAGS_x86_64_apple_ios

.PHONY: all build rust xcframework zip clean

# --- Core Build ---

all: build

build: rust

rust:
	@echo "--- Building Rust Bridge ---"

	@# iOS device (arm64)
	cd $(RUST_DIR) && cargo build --target aarch64-apple-ios --release

	@# iOS Simulator (Apple Silicon)
	cd $(RUST_DIR) && cargo build --target aarch64-apple-ios-sim --release

	@# iOS Simulator (Intel)
	cd $(RUST_DIR) && cargo build --target x86_64-apple-ios --release


# --- XCFramework from static libs (no C headers needed — Swift uses @_silgen_name) ---

xcframework: rust
	@echo "--- Building RustBridge.xcframework ---"

	@# Empty headers dir required by xcodebuild -create-xcframework -library
	mkdir -p $(RUST_DIR)/lib/headers
	mkdir -p $(RUST_DIR)/target/universal-simulator

	@# XCFramework supports a single simulator entry containing both architectures.
	xcrun lipo -create \
		$(RUST_DIR)/target/aarch64-apple-ios-sim/release/lib$(TARGET).a \
		$(RUST_DIR)/target/x86_64-apple-ios/release/lib$(TARGET).a \
		-output $(RUST_DIR)/target/universal-simulator/lib$(TARGET).a

	@# Remove stale xcframework
	rm -rf $(RUST_DIR)/lib/RustBridge.xcframework

	xcodebuild -create-xcframework \
		-library $(RUST_DIR)/target/aarch64-apple-ios/release/lib$(TARGET).a \
		-headers $(RUST_DIR)/lib/headers \
		-library $(RUST_DIR)/target/universal-simulator/lib$(TARGET).a \
		-headers $(RUST_DIR)/lib/headers \
		-output $(RUST_DIR)/lib/RustBridge.xcframework

	@# Record source fingerprint so CI/local can detect a stale prebuilt binary.
	bash $(REPO_ROOT)/Scripts/rustbridge-fingerprint.sh $(RUST_DIR) \
		> $(RUST_DIR)/lib/RustBridge.xcframework/.source-fingerprint

	@echo "--- Done: RustBridge/lib/RustBridge.xcframework (fingerprint $$(cat $(RUST_DIR)/lib/RustBridge.xcframework/.source-fingerprint | cut -c1-12)) ---"


# --- Cleanup ---

clean:
	@echo "--- Cleaning ---"
	cd $(RUST_DIR) && cargo clean
	rm -rf $(RUST_DIR)/lib
