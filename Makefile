THEOS_DEVICE_IP = localhost
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakeCamTweak

FakeCamTweak_FILES = Tweak.x
FakeCamTweak_CFLAGS = -fobjc-arc
FakeCamTweak_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo

include $(THEOS_MAKE_PATH)/tweak.mk
