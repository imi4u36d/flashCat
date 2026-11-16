// 发布构建不要带控制台窗口（Windows）。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    flashcat_lib::run();
}
