add_subdirectory(auto_code_generated)
add_subdirectory(manual_prim)
add_subdirectory(generated_prim)

if(NOT (NOT WITH_PYTHON AND ON_INFER))
  cc_library(
    prim_api
    SRCS all.cc
    DEPS static_utils static_prim_api eager_prim_api eager_api)
else()
  cc_library(
    prim_api
    SRCS all.cc
    DEPS static_utils static_prim_api)
endif()
