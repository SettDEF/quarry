cmake_minimum_required(VERSION 3.21)
project(quarry-browser LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Qml Quick WebEngineQuick)

add_executable(quarry-browser main.cpp)
target_link_libraries(quarry-browser PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::WebEngineQuick)
# Where the QML lives when running straight out of the checkout.
target_compile_definitions(quarry-browser PRIVATE
    QUARRY_BROWSER_QML="${CMAKE_CURRENT_SOURCE_DIR}/Browser.qml")

install(TARGETS quarry-browser RUNTIME DESTINATION bin)
install(FILES Browser.qml DESTINATION share/quarry/browser)
