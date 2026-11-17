# Builds upstream's own fuzzers (fuzzers/src/*.cpp, the list in fuzzers/Jamfile) against an
# instrumented libtorrent, using upstream's CMake build for the library. Each harness is compiled
# once and linked twice: with the fuzzing engine (-> <name>) and with the run-once driver
# (-> <name>-standalone). Driven by mayhem/build.sh, which passes the flags.
#
# libtorrent is built ONCE as a shared library that all 2 x N binaries load (RPATH into the build
# dir). upstream's fuzzers/Jamfile links it statically; done here that is ~275 MB per binary and
# ~17 GB for the set, which no CI runner or image registry round-trip survives. The harnesses reach
# internal (non-exported) symbols, so the library is built with default symbol visibility.
cmake_minimum_required(VERSION 3.16)
project(libtorrent_mayhem_fuzzers C CXX)

get_filename_component(LT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(MAYHEM_OUT "${LT_ROOT}" CACHE PATH "where the fuzz binaries land")
set(MAYHEM_FUZZING_ENGINE "-fsanitize=fuzzer" CACHE STRING "link flag for the fuzzing engine")
set(MAYHEM_STANDALONE_MAIN "" CACHE FILEPATH "run-once driver (C source)")
set(MAYHEM_LSAN_OFF "${LT_ROOT}/mayhem/lsan_off.cc" CACHE FILEPATH "LeakSanitizer off-switch (linked into every binary)")
set(MAYHEM_FUZZERS "" CACHE STRING "harness names (fuzzers/src/<name>.cpp)")

add_subdirectory("${LT_ROOT}" libtorrent EXCLUDE_FROM_ALL)
set_target_properties(torrent-rasterbar PROPERTIES
	CXX_VISIBILITY_PRESET default C_VISIBILITY_PRESET default VISIBILITY_INLINES_HIDDEN OFF)

add_library(mayhem_standalone_main OBJECT "${MAYHEM_STANDALONE_MAIN}")
add_library(mayhem_lsan_off OBJECT "${MAYHEM_LSAN_OFF}")
separate_arguments(_engine UNIX_COMMAND "${MAYHEM_FUZZING_ENGINE}")

foreach(name IN LISTS MAYHEM_FUZZERS)
	# mayhem/harnesses/<name>.cpp, when present, replaces upstream's fuzzers/src/<name>.cpp
	if(EXISTS "${LT_ROOT}/mayhem/harnesses/${name}.cpp")
		set(_src "${LT_ROOT}/mayhem/harnesses/${name}.cpp")
	else()
		set(_src "${LT_ROOT}/fuzzers/src/${name}.cpp")
	endif()
	add_library(${name}_obj OBJECT "${_src}")
	target_include_directories(${name}_obj PRIVATE "${LT_ROOT}/fuzzers/src")
	target_link_libraries(${name}_obj PRIVATE torrent-rasterbar)
	if(TARGET datachannel-static)
		# the WebTorrent harnesses include <rtc/rtc.hpp>; the code itself lives in the shared library
		target_include_directories(${name}_obj PRIVATE
			$<TARGET_PROPERTY:datachannel-static,INTERFACE_INCLUDE_DIRECTORIES>)
	endif()

	# the entry-based bdecode<InIt> overload only exists at ABI 1 (upstream's Jamfile builds this fuzzer
	# with <deprecated-functions>1); it is header-only, so one object compiled at ABI 1 is enough
	if(name STREQUAL "bdecode_entry")
		target_compile_options(${name}_obj PRIVATE -UTORRENT_ABI_VERSION -DTORRENT_ABI_VERSION=1)
	endif()

	add_executable(${name} $<TARGET_OBJECTS:${name}_obj> $<TARGET_OBJECTS:mayhem_lsan_off>)
	target_link_libraries(${name} PRIVATE torrent-rasterbar)
	target_link_options(${name} PRIVATE ${_engine})

	add_executable(${name}-standalone $<TARGET_OBJECTS:${name}_obj>
		$<TARGET_OBJECTS:mayhem_lsan_off> $<TARGET_OBJECTS:mayhem_standalone_main>)
	target_link_libraries(${name}-standalone PRIVATE torrent-rasterbar)

	set_target_properties(${name} ${name}-standalone PROPERTIES
		RUNTIME_OUTPUT_DIRECTORY "${MAYHEM_OUT}" LINKER_LANGUAGE CXX)
endforeach()
