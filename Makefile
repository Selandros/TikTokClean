ARCHS = arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = TikTok
THEOS_PACKAGE_SCHEME = rootless
DEBUG = 0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

_THEOS_TARGET_LDFLAGS := $(filter-out -multiply_defined suppress,$(_THEOS_TARGET_LDFLAGS))

TWEAK_NAME = TikTokClean

TikTokClean_FILES = Tweak.xm
TikTokClean_FRAMEWORKS = Foundation UIKit Photos
TikTokClean_CFLAGS = -fno-objc-arc -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 TikTok || true"
