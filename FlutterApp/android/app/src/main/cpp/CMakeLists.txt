cmake_minimum_required(VERSION 3.22.1)
project(askme_jni_bridge C)

add_library(askme_android_host SHARED IMPORTED)
set_target_properties(askme_android_host PROPERTIES
    IMPORTED_LOCATION
    "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libaskme_android_host.so")

add_library(askme_jni_bridge SHARED askme_jni_bridge.c)
target_link_libraries(askme_jni_bridge askme_android_host)
