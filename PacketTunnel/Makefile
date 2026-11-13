TARGET := iphone:clang:16.5:14.0
ARCHS = arm64

TARGET_CODESIGN = ../Exploits/fastPathSign/fastPathSign

include $(THEOS)/makefiles/common.mk

TOOL_NAME = PacketTunnel

PacketTunnel_FILES = PacketTunnelProvider.m
PacketTunnel_FRAMEWORKS = Foundation NetworkExtension
PacketTunnel_CFLAGS = -fobjc-arc -fapplication-extension
PacketTunnel_CODESIGN_FLAGS = --entitlements PacketTunnel.entitlements

include $(THEOS_MAKE_PATH)/tool.mk

after-all::
	@mkdir -p $(THEOS_OBJ_DIR)/PacketTunnel.appex
	@cp $(THEOS_OBJ_DIR)/PacketTunnel $(THEOS_OBJ_DIR)/PacketTunnel.appex/PacketTunnel
	@cp Info.plist $(THEOS_OBJ_DIR)/PacketTunnel.appex/Info.plist
