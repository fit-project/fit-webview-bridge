cmake_minimum_required(VERSION 3.21)

# Compiliamo Objective-C++ (.mm)
enable_language(OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.7 REQUIRED COMPONENTS Core Widgets Gui)

# Troviamo Homebrew e il prefix di Qt (solo per header Qt dell’SDK)
find_program(BREW_EXECUTABLE NAMES brew HINTS /opt/homebrew/bin /usr/local/bin)
if(NOT BREW_EXECUTABLE)
  message(FATAL_ERROR "Homebrew 'brew' not found. Please install Homebrew or add it to PATH.")
endif()

if(NOT DEFINED QT_HOMEBREW_ROOT OR QT_HOMEBREW_ROOT STREQUAL "")
  execute_process(
    COMMAND "${BREW_EXECUTABLE}" --prefix qt
    OUTPUT_VARIABLE QT_HOMEBREW_ROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _res
  )
  if(NOT _res EQUAL 0 OR QT_HOMEBREW_ROOT STREQUAL "")
    execute_process(
      COMMAND "${BREW_EXECUTABLE}" --prefix qt@6
      OUTPUT_VARIABLE QT_HOMEBREW_ROOT
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE _res6
    )
    if(NOT _res6 EQUAL 0 OR QT_HOMEBREW_ROOT STREQUAL "")
      message(FATAL_ERROR "Failed to resolve Qt prefix from Homebrew (tried 'qt' and 'qt@6').")
    endif()
  endif()
endif()

# --- Qt header shim (SDK headers from Homebrew)
set(QT_FRAMEWORKS_DIR "${QT_HOMEBREW_ROOT}/Frameworks")
foreach(_mod QtCore QtGui QtWidgets)
  if(NOT EXISTS "${QT_FRAMEWORKS_DIR}/${_mod}.framework/Headers")
    message(FATAL_ERROR "Missing ${_mod}.framework/Headers under: ${QT_FRAMEWORKS_DIR}")
  endif()
endforeach()
set(QT_HDRSHIM "${CMAKE_BINARY_DIR}/qt_hdrshim")
file(MAKE_DIRECTORY "${QT_HDRSHIM}")
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtCore.framework/Headers"    "${QT_HDRSHIM}/QtCore"    SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtGui.framework/Headers"     "${QT_HDRSHIM}/QtGui"     SYMBOLIC)
file(CREATE_LINK "${QT_FRAMEWORKS_DIR}/QtWidgets.framework/Headers" "${QT_HDRSHIM}/QtWidgets" SYMBOLIC)

# Header Qt dall’SDK (solo include; il link a Qt lo fa il modulo Python)
set(_QT_FW_DIR "${QT_HOMEBREW_ROOT}/Frameworks")


# Lib nativa (WKWebView + Cocoa)
add_library(wkwebview STATIC
  WKWebViewWidget.mm
  WKWebViewWidget.h
)

target_compile_features(wkwebview PRIVATE cxx_std_17)

# Se usi ARC in ObjC++, sblocca la riga sotto
# target_compile_options(wkwebview PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")

target_include_directories(wkwebview
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${_QT_FW_DIR}/QtCore.framework/Headers"
    "${_QT_FW_DIR}/QtGui.framework/Headers"
    "${_QT_FW_DIR}/QtWidgets.framework/Headers"
    ${QT_HDRSHIM}
)


# Frameworks di sistema (Cocoa/WebKit) per il codice .mm
target_link_libraries(wkwebview
  PUBLIC
    "-framework Cocoa"
    "-framework WebKit"
)