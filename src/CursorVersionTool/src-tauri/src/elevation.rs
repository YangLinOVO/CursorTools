#[cfg(windows)]
pub fn is_admin() -> bool {
    // SAFETY: Win32 IsUserAnAdmin is a simple BOOL probe.
    unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
}

#[cfg(not(windows))]
pub fn is_admin() -> bool {
    false
}

#[cfg(windows)]
pub fn restart_as_admin(extra_args: Option<&str>) -> bool {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return false,
    };
    let file: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    let operation: Vec<u16> = "runas\0".encode_utf16().collect();
    let params: Vec<u16> = extra_args
        .unwrap_or("")
        .encode_utf16()
        .chain(Some(0))
        .collect();

    // SAFETY: ShellExecuteW with NUL-terminated wide strings.
    let rc = unsafe {
        ShellExecuteW(
            0 as HWND,
            operation.as_ptr(),
            file.as_ptr(),
            params.as_ptr(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    (rc as isize) > 32
}

#[cfg(not(windows))]
pub fn restart_as_admin(_extra_args: Option<&str>) -> bool {
    false
}
