cmake_minimum_required(VERSION 3.21)
enable_language(OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui Widgets)

get_filename_component(_qt_cmake_dir "${Qt6_DIR}" DIRECTORY)       # …/macos/lib/cmake
get_filename_component(QT_FRAMEWORKS_DIR "${_qt_cmake_dir}" DIRECTORY) # …/macos/lib


foreach(_m QtCore QtGui QtWidgets)
  if(NOT EXISTS "${QT_FRAMEWORKS_DIR}/${_m}.framework/Headers")
    message(FATAL_ERROR "Missing ${_m}.framework/Headers in: ${QT_FRAMEWORKS_DIR}")
  endif()
endforeach()


set(QT_HDRSHIM "${CMAKE_BINARY_DIR}/qt_hdrshim")
file(MAKE_DIRECTORY "${QT_HDRSHIM}")
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtCore.framework/Headers"    "${QT_HDRSHIM}/QtCore"    SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtGui.framework/Headers"     "${QT_HDRSHIM}/QtGui"     SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtWidgets.framework/Headers" "${QT_HDRSHIM}/QtWidgets" SYMBOLIC)

add_library(wkwebview STATIC
  WKWebViewWidget.mm
  WKWebViewWidget.h
  DownloadInfo.h
)
target_compile_features(wkwebview PRIVATE cxx_std_17)

target_include_directories(wkwebview PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  "${QT_FRAMEWORKS_DIR}/QtCore.framework/Headers"
  "${QT_FRAMEWORKS_DIR}/QtGui.framework/Headers"
  "${QT_FRAMEWORKS_DIR}/QtWidgets.framework/Headers"
  ${QT_HDRSHIM}
)

target_link_libraries(wkwebview PUBLIC
  "-framework Cocoa"
  "-framework WebKit"
)
