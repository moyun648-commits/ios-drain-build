# Theos tweak 构建（rootless，供 TrollFools 注入 / Dopamine deb）
# 本地没有 macOS？用 .github/workflows/build-ios.yml 在 CI 上编。

TARGET := iphone:clang:16.5:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DrainTweak
DrainTweak_FILES = Tweak.xm
DrainTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DrainTweak_FRAMEWORKS = UIKit Foundation

# rootless（Dopamine / TrollStore 用）
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
