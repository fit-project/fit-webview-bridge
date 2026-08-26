cmake_minimum_required(VERSION 3.24)

set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui Widgets)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WEBKITGTK REQUIRED IMPORTED_TARGET webkit2gtk-4.1)

add_library(systemwebview_linux STATIC
  SystemWebViewWidget.cpp
  "${PROJECT_SOURCE_DIR}/include/fit_webview_bridge/SystemWebViewWidget.h"
  "${PROJECT_SOURCE_DIR}/include/fit_webview_bridge/DownloadInfo.h"
)
set_target_properties(systemwebview_linux PROPERTIES POSITION_INDEPENDENT_CODE ON)

target_compile_features(systemwebview_linux PRIVATE cxx_std_17)
target_include_directories(systemwebview_linux PUBLIC "${PROJECT_SOURCE_DIR}/include")
target_link_libraries(systemwebview_linux PUBLIC
  Qt6::Core
  Qt6::Gui
  Qt6::Widgets
  PkgConfig::WEBKITGTK
)
