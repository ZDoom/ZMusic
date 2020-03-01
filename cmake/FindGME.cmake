# - Find game-music-emu
# Find the native gme includes and library
#
#  GME_INCLUDE_DIR - where to find gme.h
#  GME_LIBRARIES   - List of libraries when using GME
#  GME_FOUND       - True if GME found.

if(GME_INCLUDE_DIR AND GME_LIBRARIES)
    # Already in cache, be silent
    set(GME_FIND_QUIETLY TRUE)
endif()

find_path(GME_INCLUDE_DIR gme/gme.h)

find_library(GME_LIBRARIES NAMES gme)
set(GME_INCLUDE_DIRS ${GME_INCLUDE_DIR})
set(GME_LIBRARIES ${GME_LIBRARY})
mark_as_advanced(GME_LIBRARIES GME_INCLUDE_DIR)

# handle the QUIETLY and REQUIRED arguments and set GME_FOUND to TRUE if 
# all listed variables are TRUE
include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(GME DEFAULT_MSG GME_LIBRARIES GME_INCLUDE_DIR)
