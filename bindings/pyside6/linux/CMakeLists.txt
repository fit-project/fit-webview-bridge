cmake_minimum_required(VERSION 3.24)

find_package(Python3 REQUIRED COMPONENTS Interpreter Development.Module)
find_package(Qt6 6.9 REQUIRED COMPONENTS Core Gui Widgets)
find_program(SHIBOKEN6_GEN shiboken6 REQUIRED)

execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import os, shiboken6; print(os.path.join(os.path.dirname(shiboken6.__file__), 'typesystems'))"
  OUTPUT_VARIABLE SHIBOKEN_TYPESYSTEMS OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'typesystems'))"
  OUTPUT_VARIABLE PYSIDE_TYPESYSTEMS OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import os, shiboken6; print(os.path.join(os.path.dirname(shiboken6.__file__), 'include'))"
  OUTPUT_VARIABLE SHIBOKEN_INCLUDE_DIR OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT EXISTS "${SHIBOKEN_INCLUDE_DIR}/shiboken.h")
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" -c "import os, shiboken6_generator; print(os.path.join(os.path.dirname(shiboken6_generator.__file__), 'include'))"
    OUTPUT_VARIABLE SHIBOKEN_INCLUDE_DIR OUTPUT_STRIP_TRAILING_WHITESPACE
  )
endif()
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'include'))"
  OUTPUT_VARIABLE PYSIDE_INCLUDE_DIR OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import glob, os, shiboken6; print((glob.glob(os.path.join(os.path.dirname(shiboken6.__file__), 'libshiboken6*.so*')) or [''])[0])"
  OUTPUT_VARIABLE SHIBOKEN_LIBRARY OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import glob, os, PySide6; print((glob.glob(os.path.join(os.path.dirname(PySide6.__file__), 'libpyside6.abi3.so*')) or [''])[0])"
  OUTPUT_VARIABLE PYSIDE_LIBRARY OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import os, PySide6; print(os.path.join(os.path.dirname(PySide6.__file__), 'Qt', 'lib'))"
  OUTPUT_VARIABLE PYSIDE_QT_LIBDIR OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX') or '.so')"
  OUTPUT_VARIABLE PY_EXT_SUFFIX OUTPUT_STRIP_TRAILING_WHITESPACE
)

foreach(required_path
    "${SHIBOKEN_INCLUDE_DIR}/shiboken.h"
    "${PYSIDE_INCLUDE_DIR}"
    "${SHIBOKEN_LIBRARY}"
    "${PYSIDE_LIBRARY}"
    "${PYSIDE_QT_LIBDIR}")
  if(NOT EXISTS "${required_path}")
    message(FATAL_ERROR "Required PySide6/Shiboken6 path not found: ${required_path}")
  endif()
endforeach()

get_target_property(QTCORE_INCLUDE_DIRS Qt6::Core INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(QTGUI_INCLUDE_DIRS Qt6::Gui INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(QTWIDGETS_INCLUDE_DIRS Qt6::Widgets INTERFACE_INCLUDE_DIRECTORIES)
set(SHIBOKEN_INCLUDE_LIST
  "${PROJECT_SOURCE_DIR}/include"
  "${SHIBOKEN_INCLUDE_DIR}"
  "${PYSIDE_INCLUDE_DIR}"
  "${PYSIDE_INCLUDE_DIR}/QtCore"
  "${PYSIDE_INCLUDE_DIR}/QtGui"
  "${PYSIDE_INCLUDE_DIR}/QtWidgets"
  ${QTCORE_INCLUDE_DIRS}
  ${QTGUI_INCLUDE_DIRS}
  ${QTWIDGETS_INCLUDE_DIRS}
)
list(REMOVE_DUPLICATES SHIBOKEN_INCLUDE_LIST)
list(JOIN SHIBOKEN_INCLUDE_LIST ":" SHIBOKEN_INCLUDE_ARG)

# The PyPI Shiboken generator embeds libclang, but on some Linux systems it
# detects a partial LLVM installation without Clang's builtin headers.  Feed it
# the builtin include directory of the compiler selected by CMake so headers
# such as stddef.h remain available to the parser.
execute_process(
  COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=include
  OUTPUT_VARIABLE CXX_BUILTIN_INCLUDE_DIR
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE CXX_BUILTIN_INCLUDE_RV
)
set(SHIBOKEN_SYSTEM_INCLUDE_OPTIONS)
if(CXX_BUILTIN_INCLUDE_RV EQUAL 0
    AND IS_DIRECTORY "${CXX_BUILTIN_INCLUDE_DIR}")
  list(APPEND SHIBOKEN_SYSTEM_INCLUDE_OPTIONS
    "--system-include-paths=${CXX_BUILTIN_INCLUDE_DIR}"
  )
endif()

set(GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/shiboken_out")
file(MAKE_DIRECTORY "${GEN_DIR}")
set(HEADERS "${PROJECT_SOURCE_DIR}/include/fit_webview_bridge/SystemWebViewWidget.h")
set(TYPESYSTEM "${PROJECT_SOURCE_DIR}/bindings/pyside6/typesystem_systemwebview.xml")

execute_process(
  COMMAND "${SHIBOKEN6_GEN}"
    --generator-set=shiboken
    --enable-pyside-extensions
    ${SHIBOKEN_SYSTEM_INCLUDE_OPTIONS}
    --include-paths=${SHIBOKEN_INCLUDE_ARG}
    --typesystem-paths=${SHIBOKEN_TYPESYSTEMS}
    --typesystem-paths=${PYSIDE_TYPESYSTEMS}
    --output-directory=${GEN_DIR}
    ${HEADERS}
    ${TYPESYSTEM}
  RESULT_VARIABLE SHIBOKEN_RV
  OUTPUT_VARIABLE SHIBOKEN_STDOUT
  ERROR_VARIABLE SHIBOKEN_STDERR
  WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
)
if(NOT SHIBOKEN_RV EQUAL 0)
  message(STATUS "Shiboken stdout:\n${SHIBOKEN_STDOUT}")
  message(STATUS "Shiboken stderr:\n${SHIBOKEN_STDERR}")
  message(FATAL_ERROR "Shiboken generation failed with code ${SHIBOKEN_RV}")
endif()

file(GLOB_RECURSE SHIBOKEN_SRCS CONFIGURE_DEPENDS "${GEN_DIR}/*.cpp")
if(NOT SHIBOKEN_SRCS)
  message(FATAL_ERROR "No Shiboken sources generated in ${GEN_DIR}")
endif()

add_library(_systemwebview MODULE ${SHIBOKEN_SRCS})
target_compile_features(_systemwebview PRIVATE cxx_std_17)
target_include_directories(_systemwebview PRIVATE
  "${GEN_DIR}"
  "${PROJECT_SOURCE_DIR}/include"
  ${Python3_INCLUDE_DIRS}
  "${SHIBOKEN_INCLUDE_DIR}"
  "${PYSIDE_INCLUDE_DIR}"
  "${PYSIDE_INCLUDE_DIR}/QtCore"
  "${PYSIDE_INCLUDE_DIR}/QtGui"
  "${PYSIDE_INCLUDE_DIR}/QtWidgets"
)
target_link_libraries(_systemwebview PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::Widgets
  "${SHIBOKEN_LIBRARY}"
  "${PYSIDE_LIBRARY}"
  Python3::Module
  systemwebview_linux
)

get_filename_component(SHIBOKEN_LIB_DIR "${SHIBOKEN_LIBRARY}" DIRECTORY)
get_filename_component(PYSIDE_LIB_DIR "${PYSIDE_LIBRARY}" DIRECTORY)
set_target_properties(_systemwebview PROPERTIES
  PREFIX ""
  OUTPUT_NAME "systemwebview"
  SUFFIX "${PY_EXT_SUFFIX}"
  LIBRARY_OUTPUT_DIRECTORY "${PROJECT_SOURCE_DIR}/fit_webview_bridge"
  BUILD_RPATH "$ORIGIN;${PYSIDE_QT_LIBDIR};${SHIBOKEN_LIB_DIR};${PYSIDE_LIB_DIR}"
  INSTALL_RPATH "$ORIGIN;$ORIGIN/../PySide6/Qt/lib;$ORIGIN/../PySide6;$ORIGIN/../shiboken6"
)

install(TARGETS _systemwebview
  LIBRARY DESTINATION fit_webview_bridge
  RUNTIME DESTINATION fit_webview_bridge
)
