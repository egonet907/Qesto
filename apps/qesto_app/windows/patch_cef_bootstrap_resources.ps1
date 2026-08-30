param(
    [Parameter(Mandatory = $true)]
    [string]$BootstrapPath,

    [Parameter(Mandatory = $true)]
    [string]$ResourceSourcePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bootstrap = [System.IO.Path]::GetFullPath($BootstrapPath)
$resourceSource = [System.IO.Path]::GetFullPath($ResourceSourcePath)
if (-not [System.IO.File]::Exists($bootstrap)) {
    throw "CEF bootstrap not found: $bootstrap"
}
if (-not [System.IO.File]::Exists($resourceSource)) {
    throw "Qesto resource source not found: $resourceSource"
}

# MSBuild launches the install step with its native LIB search path in the
# environment. Windows PowerShell's legacy Add-Type compiler treats that value
# as a C# reference path and can fail on quoted Visual Studio directories.
# This helper only uses framework assemblies, so an empty LIB is intentional.
$env:LIB = $null

Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class QestoVersionResourcePatch {
    private const uint LoadLibraryAsDataFile = 0x00000002;
    private static readonly IntPtr RtVersion = new IntPtr(16);
    private static readonly IntPtr VersionResourceId = new IntPtr(1);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(
        string fileName,
        IntPtr file,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr FindResourceW(
        IntPtr module,
        IntPtr name,
        IntPtr type);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LockResource(IntPtr resourceData);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BeginUpdateResourceW(
        string fileName,
        bool deleteExistingResources);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateResourceW(
        IntPtr update,
        IntPtr type,
        IntPtr name,
        ushort language,
        byte[] data,
        uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResourceW(IntPtr update, bool discard);

    private static Win32Exception Error(string operation) {
        return new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    public static void CopyVersion(string sourcePath, string targetPath) {
        IntPtr module = LoadLibraryExW(sourcePath, IntPtr.Zero, LoadLibraryAsDataFile);
        if (module == IntPtr.Zero) throw Error("LoadLibraryExW");
        try {
            IntPtr resource = FindResourceW(module, VersionResourceId, RtVersion);
            if (resource == IntPtr.Zero) throw Error("FindResourceW(RT_VERSION)");
            uint size = SizeofResource(module, resource);
            if (size == 0) throw Error("SizeofResource(RT_VERSION)");
            IntPtr loaded = LoadResource(module, resource);
            if (loaded == IntPtr.Zero) throw Error("LoadResource(RT_VERSION)");
            IntPtr dataPointer = LockResource(loaded);
            if (dataPointer == IntPtr.Zero) throw Error("LockResource(RT_VERSION)");
            byte[] data = new byte[size];
            Marshal.Copy(dataPointer, data, 0, checked((int)size));

            IntPtr update = BeginUpdateResourceW(targetPath, false);
            if (update == IntPtr.Zero) throw Error("BeginUpdateResourceW");
            bool committed = false;
            try {
                // Runner.rc uses English (United States), code page 1252.
                if (!UpdateResourceW(
                        update, RtVersion, VersionResourceId, 0x0409, data, size)) {
                    throw Error("UpdateResourceW(RT_VERSION)");
                }
                if (!EndUpdateResourceW(update, false)) {
                    throw Error("EndUpdateResourceW");
                }
                committed = true;
            } finally {
                if (!committed) EndUpdateResourceW(update, true);
            }
        } finally {
            FreeLibrary(module);
        }
    }
}
'@

[QestoVersionResourcePatch]::CopyVersion($resourceSource, $bootstrap)
$version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($bootstrap)
if ($version.ProductName -ne 'Qesto' -or $version.CompanyName -ne 'ru.qesto') {
    throw "CEF bootstrap identity patch verification failed: '$($version.CompanyName)' / '$($version.ProductName)'"
}

Write-Output "Patched CEF bootstrap identity: $($version.CompanyName) / $($version.ProductName)"
