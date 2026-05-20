#pragma once
#include <string>

// Stubs for globals previously defined in ui.cpp / config.cpp
extern bool TOUCH_MODE;

// Stub ConfigManager — returns hardcoded defaults.
// The real config system has been removed; control comes from the socket layer.
class ConfigManager {
public:
    template<typename T>
    const T* get_config(const std::wstring& key) const {
        static float search_highlight[3]  = { 0.0f, 0.0f, 1.0f };  // blue
        static float link_highlight[3]    = { 0.0f, 1.0f, 0.0f };  // green
        if (key == L"search_highlight_color") return reinterpret_cast<const T*>(search_highlight);
        if (key == L"link_highlight_color")   return reinterpret_cast<const T*>(link_highlight);
        return nullptr;
    }
};
