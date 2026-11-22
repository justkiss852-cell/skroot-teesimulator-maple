LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := module_teesimulator_maple

LOCAL_SRC_FILES := \
    $(LOCAL_PATH)/../module_teesimulator_maple.cpp

# 本工程应当放在 SKRoot 仓库的 .../src/testModule/ 目录下，
# 这样 ../../kernel_module_kit 才能指向官方 SDK。
KERNEL_MODULE_KIT := $(LOCAL_PATH)/../../kernel_module_kit
LOCAL_C_INCLUDES += $(KERNEL_MODULE_KIT)/include
# 模块自己的头文件（tee_utils.h）所在目录
LOCAL_C_INCLUDES += $(LOCAL_PATH)/..
LOCAL_LDFLAGS += $(KERNEL_MODULE_KIT)/lib/libkernel_module_kit_static.a

include $(LOCAL_PATH)/build_macros.mk

include $(BUILD_SHARED_LIBRARY)
